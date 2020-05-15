module _PyJuliaHelper

import REPL
using PyCall
using PyCall: pyeval_, Py_eval_input, Py_file_input
using PyCall.MacroTools: isexpr, walk

"""
    fullnamestr(m)

# Examples
```jldoctest
julia> fullnamestr(Base.Enums)
"Base.Enums"
```
"""
fullnamestr(m) = join(fullname(m), ".")

isdefinedstr(parent, member) = isdefined(parent, Symbol(member))

function completions(str, pos)
    ret, ran, should_complete = REPL.completions(str, pos)
    return (
        map(REPL.completion_text, ret),
        (first(ran), last(ran)),
        should_complete,
    )
end


# takes an expression like `$foo + 1` and turns it into a pyfunction
# `(globals,locals) -> convert(PyAny, pyeval_("foo",globals,locals,PyAny)) + 1`
# so that Python code can call it and just pass the appropriate globals/locals
# dicts to perform the interpolation. 
macro prepare_for_pyjulia_call(ex)
    
    # f(x, quote_depth) should return a transformed expression x and whether to
    # recurse into the new expression. quote_depth keeps track of how deep
    # inside of nested quote objects we are
    function stoppable_walk(f, x, quote_depth=1)
        (fx, recurse) = f(x, quote_depth)
        if isexpr(fx,:quote)
            quote_depth += 1
        end
        if isexpr(fx,:$)
            quote_depth -= 1
        end
        walk(fx, (recurse ? (x -> stoppable_walk(f,x,quote_depth)) : identity), identity)
    end
    
    function insert_pyevals(globals, locals, ex)
        stoppable_walk(ex) do x, quote_depth
            if quote_depth==1 && isexpr(x, :$)
                if x.args[1] isa Symbol
                    :(PyCall.@_py_str($globals, $locals, $(string(x.args[1])))), false
                else
                    error("""syntax error in: \$($(string(x.args[1])))
                    Use py"..." instead of \$(...) for interpolating Python expressions.""")
                end
            elseif quote_depth==1 && isexpr(x, :macrocall)
                if x.args[1]==Symbol("@py_str")
                    # in Julia 0.7+, x.args[2] is a LineNumberNode, so filter it out
                    # in a way that's compatible with Julia 0.6:
                    code_and_options = filter(s->(s isa String), x.args[2:end])
                    :(PyCall.@_py_str($globals, $locals, $(code_and_options...))), false
                else
                    x, false
                end
            else
                x, true
            end
        end
    end
    
    esc(quote
        $pyfunction(
            (globals, locals)->Base.eval(Main, $insert_pyevals(globals, locals, $(QuoteNode(ex)))),
            $PyDict, $PyDict
        )
    end)
end


module IOPiper

const orig_stdin  = Ref{IO}()
const orig_stdout = Ref{IO}()
const orig_stderr = Ref{IO}()

function __init__()
    orig_stdin[]  = stdin
    orig_stdout[] = stdout
    orig_stderr[] = stderr
end

"""
    num_utf8_trailing(d::Vector{UInt8})

If `d` ends with an incomplete UTF8-encoded character, return the number of trailing incomplete bytes.
Otherwise, return `0`.

Taken from IJulia.jl.
"""
function num_utf8_trailing(d::Vector{UInt8})
    i = length(d)
    # find last non-continuation byte in d:
    while i >= 1 && ((d[i] & 0xc0) == 0x80)
        i -= 1
    end
    i < 1 && return 0
    c = d[i]
    # compute number of expected UTF-8 bytes starting at i:
    n = c <= 0x7f ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4
    nend = length(d) + 1 - i # num bytes from i to end
    return nend == n ? 0 : nend
end

function pipe_stream(sender::IO, receiver, buf::IO = IOBuffer())
    try
        while !eof(sender)
            nb = bytesavailable(sender)
            write(buf, read(sender, nb))

            # Taken from IJulia.send_stream:
            d = take!(buf)
            n = num_utf8_trailing(d)
            dextra = d[end-(n-1):end]
            resize!(d, length(d) - n)
            s = String(copy(d))

            write(buf, dextra)
            receiver(s)  # check isvalid(String, s)?
        end
    catch e
        if !isa(e, InterruptException)
            rethrow()
        end
        pipe_stream(sender, receiver, buf)
    end
end

const read_stdout = Ref{Base.PipeEndpoint}()
const read_stderr = Ref{Base.PipeEndpoint}()

function pipe_std_outputs(out_receiver, err_receiver)
    global readout_task
    global readerr_task
    read_stdout[], = redirect_stdout()
    readout_task = @async pipe_stream(read_stdout[], out_receiver)
    read_stderr[], = redirect_stderr()
    readerr_task = @async pipe_stream(read_stderr[], err_receiver)
end

end  # module

end  # module
