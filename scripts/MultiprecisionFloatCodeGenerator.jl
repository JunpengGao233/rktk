baremodule MultiprecisionFloatCodeGenerator

export one_pass_renorm_func, two_pass_renorm_func, MF64_alias,
    MF64_add_func, MF64_F64_add_func, MF64_mul_func, MF64_F64_mul_func,
    MF64_div_func, MF64_sqrt_func

using Base: +, -, *, div, !, (:), ==, !=, <, <=, >, >=, min, max,
    Vector, length, push!, deleteat!, reverse!, Dict, haskey, @assert

################################################################################

const SymExpr = Union{Symbol,Expr}
_tuple(x...) = Expr(:tuple, x...)

# _empty_body() = Expr[]
_empty_body() = [Expr(:meta, :inline)] # same as @inline

_func(name::Symbol, args::Vector{Expr}, body::Vector{Expr}) =
    Expr(:function, Expr(:call, name, args...), Expr(:block, body...))
_func_F64(name::Symbol, args::Vector{Symbol}, body::Vector{Expr}) =
    _func(name, [Expr(:(::), arg, :Float64) for arg in args], body)
_func_MF64(name::Symbol, args::Vector{Symbol}, n::Int, body::Vector{Expr}) =
    _func(name, [Expr(:(::), arg, _MF64(n)) for arg in args], body)

_two_sum(s::Symbol, e::Symbol, a::SymExpr, b::SymExpr) =
    Expr(:(=), _tuple(s, e), Expr(:call, :two_sum, a, b))
_two_prod(p::Symbol, e::Symbol, a::SymExpr, b::SymExpr) =
    Expr(:(=), _tuple(p, e), Expr(:call, :two_prod, a, b))
_quick_two_sum(s::Symbol, e::Symbol, a::Symbol, b::Symbol) =
    Expr(:(=), _tuple(s, e), Expr(:call, :quick_two_sum, a, b))

_sum(addends::Vector{Symbol}) =
    length(addends) == 1 ? addends[1] : Expr(:call, :+, addends...)
_sum(result::Symbol, addends::Vector{Symbol}) =
    Expr(:(=), result, _sum(addends))

_renorm(n::Int) = Symbol("renorm_", n)
_mpadd(src_len::Int, dst_len::Int) = Symbol("mpadd_", src_len, '_', dst_len)
_MF64(n::Int) = Expr(:curly, :MultiFloat64, n)

################################################################################

function one_pass_renorm_func(n::Int; sloppy::Bool=false)
    args = [Symbol('a', i) for i = 0 : n - sloppy]
    sums = [Symbol('s', i) for i = 0 : n - 1]
    if (n == 2) && sloppy
        return _func_F64(_renorm(2), args,
            [Expr(:call, :quick_two_sum, args...)])
    end
    code = _empty_body()
    push!(code, _quick_two_sum(sums[1], sums[2], args[1], args[2]))
    for i = 1 : n-2
        push!(code, _quick_two_sum(sums[i+1], sums[i+2], sums[i+1], args[i+2]))
    end
    push!(code, sloppy ? _tuple(sums...) :
        _tuple(sums[1:n-1]..., Expr(:call, :+, sums[n], args[n+1])))
    _func_F64(_renorm(n), args, code)
end

function two_pass_renorm_func(n::Int; sloppy::Bool=false)
    args = [Symbol('a', i) for i = 0 : n - sloppy]
    sums = [Symbol('s', i) for i = 0 : n - 1]
    if (n == 2) && sloppy
        return _func_F64(_renorm(2), args,
            [Expr(:call, :quick_two_sum, args...)])
    end
    temp = Symbol('t')
    code = _empty_body()
    push!(code, _quick_two_sum(temp, args[end], args[end-1], args[end]))
    for i = n-2-sloppy : -1 : 1
        push!(code, _quick_two_sum(temp, args[i+2], args[i+1], temp))
    end
    push!(code, _quick_two_sum(sums[1], sums[2], args[1], temp))
    for i = 1 : n-2
        push!(code, _quick_two_sum(sums[i+1], sums[i+2], sums[i+1], args[i+2]))
    end
    push!(code, sloppy ? _tuple(sums...) :
        _tuple(sums[1:n-1]..., Expr(:call, :+, sums[n], args[n+1])))
    _func_F64(_renorm(n), args, code)
end

################################################################################

function add_var!(vars::Vector{Tuple{Symbol,Int}}, prefix::Char, i::Int)
    var = Symbol(prefix, i)
    push!(vars, (var, i))
    var
end

function add_var!(vars::Vector{Tuple{Symbol,Int}}, prefix::Char, i::Int, j::Int)
    var = Symbol(prefix, i, '_', j)
    push!(vars, (var, j))
    var
end

function mpadd_func(src_len::Int, dst_len::Int)
    @assert src_len >= dst_len
    args = [Symbol('a', i) for i = 1 : src_len]
    sums = [Symbol('s', i) for i = 0 : dst_len - 1]
    vars = [(a, 0) for a in args]
    code = _empty_body()
    k = 0
    for i = 0 : dst_len-2
        while true
            addends = [v[1] for v in vars if v[2] == i]
            if length(addends) == 1
                push!(code, Expr(:(=), sums[i+1], addends[1]))
                deleteat!(vars, [v[1] == addends[1] for v in vars])
                break
            end
            for j = 1 : div(length(addends), 2)
                a, b = addends[2*j-1], addends[2*j]
                push!(code, _two_sum(add_var!(vars, 'm', k, i),
                    add_var!(vars, 'm', k+1, i+1), a, b))
                k += 2
                deleteat!(vars, [v[1] == a || v[1] == b for v in vars])
            end
        end
    end
    push!(code, _sum(sums[dst_len], [v[1] for v in vars]))
    push!(code, _tuple(sums...))
    _func_F64(_mpadd(src_len, dst_len), args, code)
end

const MPADD_CACHE = Dict{Symbol,Expr}()

function _mpsum(results::Vector{Symbol}, addends::Vector{Symbol})
    src_len = length(addends)
    dst_len = length(results)
    @assert src_len >= dst_len
    if dst_len == 1
        _sum(results[1], addends)
    elseif src_len == dst_len == 2
        _two_sum(results[1], results[2], addends[1], addends[2])
    else
        func_name = _mpadd(src_len, dst_len)
        if !haskey(MPADD_CACHE, func_name)
            MPADD_CACHE[func_name] = mpadd_func(src_len, dst_len)
        end
        Expr(:(=), _tuple(results...), Expr(:call, func_name, addends...))
    end
end

function generate_accumulation_code!(code::Vector{Expr},
        vars::Vector{Tuple{Symbol,Int}}, N::Int; sloppy::Bool=false)
    sums = [Symbol('s', i) for i = 0 : N - sloppy]
    for i = 0 : N - sloppy
        addends = [v[1] for v in vars if v[2] == i]
        results = [sums[i+1]]
        for j = i + 1 : min(i + length(addends) - 1, N - sloppy)
            push!(results, add_var!(vars, 'm', i, j))
        end
        push!(code, _mpsum(results, addends))
        deleteat!(vars, [v[2] <= i for v in vars])
    end
    push!(code, Expr(:call, _MF64(N), Expr(:call, _renorm(N), sums...)))
end

################################################################################

MF64_alias(N::Int) = Expr(:const, Expr(:(=), Symbol("Float64x", N), _MF64(N)))

function MF64_add_func(N::Int; sloppy::Bool=false)
    code = _empty_body()
    vars = Tuple{Symbol,Int}[]
    for i = 1 : N - sloppy
        tmp = add_var!(vars, 't', i-1)
        err = add_var!(vars, 'e', i)
        push!(code, _two_sum(tmp, err, :(a.x[$i]), :(b.x[$i])))
    end
    if sloppy
        tmp = add_var!(vars, 't', N-1)
        push!(code, :($tmp = a.x[$N] + b.x[$N]))
    end
    reverse!(vars)
    generate_accumulation_code!(code, vars, N, sloppy=sloppy)
    _func_MF64(:+, [:a, :b], N, code)
end

function MF64_F64_add_func(N::Int; sloppy::Bool=false)
    code = _empty_body()
    vars = Tuple{Symbol,Int}[]
    push!(code, _two_sum(add_var!(vars, 't', 0), add_var!(vars, 'e', 1),
        :(a.x[1]), :b))
    for i = 2 : N
        push!(code, Expr(:(=), add_var!(vars, 't', i-1), :(a.x[$i])))
    end
    reverse!(vars)
    generate_accumulation_code!(code, vars, N, sloppy=sloppy)
    _func(:+, [Expr(:(::), :a, _MF64(N)), Expr(:(::), :b, :Float64)], code)
end

function MF64_mul_func(N::Int; sloppy::Bool=false)
    code = _empty_body()
    for i = 0 : N-1-sloppy, j = 0 : i
        push!(code, _two_prod(Symbol('t', j, '_', i),
            Symbol('e', j, '_', i+1), :(a.x[$(j+1)]), :(b.x[$(i-j+1)])))
    end
    for i = 0 : N-2+sloppy
        push!(code, Expr(:(=), Symbol('t', i, '_', N - sloppy),
            :(a.x[$(i + 2 - sloppy)] * b.x[$(N - i)])))
    end
    vars = Tuple{Symbol,Int}[]
    for i = 0 : N-1-sloppy, j = 0 : i; add_var!(vars, 't', j, i);        end
    for i = 0 : N-2+sloppy;            add_var!(vars, 't', i, N-sloppy); end
    for i = 0 : N-1-sloppy, j = 0 : i; add_var!(vars, 'e', j, i+1);      end
    generate_accumulation_code!(code, vars, N, sloppy=sloppy)
    _func_MF64(:*, [:a, :b], N, code)
end

function MF64_F64_mul_func(N::Int; sloppy::Bool=false)
    code = _empty_body()
    for i = 0 : N-1-sloppy
        push!(code, _two_prod(Symbol('t', i), Symbol('e', i+1),
            :(a.x[$(i+1)]), :b))
    end
    if sloppy; push!(code, Expr(:(=), Symbol('t', N-1), :(a.x[$N] * b))); end
    vars = Tuple{Symbol,Int}[]
    for i = 0 : N-1;      add_var!(vars, 't', i); end
    for i = 1 : N-sloppy; add_var!(vars, 'e', i); end
    generate_accumulation_code!(code, vars, N, sloppy=sloppy)
    _func(:*, [Expr(:(::), :a, _MF64(N)), Expr(:(::), :b, :Float64)], code)
end

function MF64_div_func(N::Int; sloppy::Bool=false)
    code = _empty_body()
    quots = [Symbol('q', i) for i = 0 : N - sloppy]
    push!(code, :($(quots[1]) = a.x[1] / b.x[1]))
    push!(code, :(r = a - b * $(quots[1])))
    for i = 2 : N-sloppy
        push!(code, :($(quots[i]) = r.x[1] / b.x[1]))
        push!(code, :(r -= b * $(quots[i])))
    end
    push!(code, :($(quots[N+1-sloppy]) = r.x[1] / b.x[1]))
    push!(code, Expr(:call, _MF64(N), Expr(:call, _renorm(N), quots...)))
    _func_MF64(:/, [:a, :b], N, code)
end

num_sqrt_iters(N::Int, sloppy::Bool) =
    (2 <= N <= 3) ? 2 :
    (4 <= N <= 5) ? 3 :
    sloppy ? div(N + 1, 2) : div(N + 2, 2)

function MF64_sqrt_func(N::Int; sloppy::Bool=false)
    code = _empty_body()
    push!(code, :(r = MultiFloat64{$N}(inv(sqrt(x.x[1])))))
    push!(code, :(h = scale(0.5, x)))
    for _ = 1 : num_sqrt_iters(N, sloppy)
        push!(code, :(r += r * (0.5 - h * (r * r))))
    end
    push!(code, :(r * x))
    _func_MF64(:sqrt, [:x], N, code)
end

end # module MultiprecisionFloatCodeGenerator
