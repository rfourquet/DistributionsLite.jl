## Const

struct Const{T} <: Distribution{T}
    x::T
end

rand(::AbstractRNG, sp::SamplerTrivial{<:Const}) = sp[].x


## algebra

struct Op2{T,F,A,B} <: Distribution{T}
    f::F
    a::A
    b::B

    Op2{T}(f::F, a::A, b::B) where {T,F,A,B} = new{T,F,A,B}(f, a, b)
end

Op2(f::F, a::A, b::B) where {F,A,B} =
    Op2{typeof(f(one(gentype(a)), one(gentype(b))))}(f, a, b)

Sampler(RNG::Type{<:AbstractRNG}, x::Op2, n::Repetition) =
    SamplerTag{typeof(x)}((f = x.f,
                           a = Sampler(RNG, x.a, n),
                           b = Sampler(RNG, x.b, n)))

function reset!(sp::SamplerTag{<:Op2}, n...)
    reset!(sp.data.a, n...)
    reset!(sp.data.b, n...)
    sp
end

rand(rng::AbstractRNG, sp::SamplerTag{<:Op2{T}}) where {T} =
    sp.data.f(rand(rng, sp.data.a), rand(rng, sp.data.b))::T


### instances

for op = (:+, :-, :*, :/, :^)
    @eval begin
        (Base.$op)(a::Distribution, b::Distribution) = Op2($op, a,        b)
        (Base.$op)(a,               b::Distribution) = Op2($op, Const(a), b)
        (Base.$op)(a::Distribution, b              ) = Op2($op, a,        Const(b))
    end
end


### getindex

Op2(::typeof(getindex), a::A, b::B) where {A,B} =
    Op2{eltype(gentype(a))}(getindex, a, b)

"""
    getindex(X::Distribution, Y::Distribution) :: Distribution

Return a distribution yielding `x[y]` where `x <- X` and `y <- Y`.

# Examples
```julia
julia> rand(Const('a':'z')[Uniform(1:3)])
'b': ASCII/Unicode U+0062 (category Ll: Letter, lowercase)
```
"""
Base.getindex(a::Distribution, b::Distribution) = Op2(getindex, a, b)


## Filter

struct Filter{T,F,D<:Distribution{T}} <: Distribution{T}
    f::F
    d::D
end

Filter(f::F, d) where {F} = Filter(f, Uniform(d))


### sampling

Sampler(RNG::Type{<:AbstractRNG}, d::Filter, n::Repetition) =
    SamplerTag{typeof(d)}((f = d.f,
                           d = Sampler(RNG, d.d, n)))

reset!(sp::SamplerTag{<:Filter}, n=0) = (reset!(sp.data.d, n); sp)

rand(rng::AbstractRNG, sp::SamplerTag{<:Filter}) =
    while true
        x = rand(rng, sp.data.d)
        sp.data.f(x) && return x
    end


## Map

struct Map{T,F,D} <: Distribution{T}
    f::F
    d::D
end

Map{T}(f::F, d...) where {T,F} = Map{T,F,typeof(d)}(f, d)

function Map(f::F, d...) where {F}
    rt = Base.return_types(f, map(gentype, d))
    T = length(rt) > 1 ? Any : rt[1]
    Map{T}(f, d...)
end


### sampling

# Repetition -> Val(1)
rand(rng::AbstractRNG, sp::SamplerTrivial{<:Map{T}}) where {T} =
    convert(T, sp[].f((rand(rng, d) for d in sp[].d)...))

Sampler(RNG::Type{<:AbstractRNG}, m::Map, n::Val{Inf}) =
    SamplerTag{typeof(m)}((f = m.f,
                           d = map(x -> Sampler(RNG, x, n), m.d)))

reset!(sp::SamplerTag{<:Map}, n=0) =
    (foreach(s -> reset!(s, n), sp.data.d); sp)

rand(rng::AbstractRNG, sp::SamplerTag{<:Map{T}}) where {T} =
    convert(T, sp.data.f((rand(rng, d) for d in sp.data.d)...))


## Reduce

struct Reduce{T,F,D} <: Distribution{T}
    f::F
    d::D
end

Reduce{T}(f::F, d) where {T,F} = Reduce{T,F,typeof(d)}(f, d)

# we only support reduce for f(::X, ::X) -> X
# use Map + Base.reduce for more complicated cases
Reduce(f::F, d) where {F} = Reduce{eltype(gentype(d))}(f, d)


### sampling

rand(rng::AbstractRNG, sp::SamplerTrivial{<:Reduce{T}}) where {T} =
    convert(T, reduce(sp[].f, rand(rng, sp[].d)))

Sampler(RNG::Type{<:AbstractRNG}, r::Reduce, n::Val{Inf}) =
    SamplerTag{typeof(r)}((f = r.f,
                           d = Sampler(RNG, r.d, n)))

reset!(sp::SamplerTag{<:Reduce}, n=0) = (reset!(sp.data.d, n); sp)

rand(rng::AbstractRNG, sp::SamplerTag{<:Reduce{T}}) where {T} =
    convert(T, reduce(sp.data.f, rand(rng, sp.data.d)))


## Counts

"""
    Counts(x) :: Distribution{<:Dict}

Create a distribution yielding a dictionary whose keys are the elements
of the collection yielded by distribution `x`, and whose values are the
number of times each element appeared in the collection.

# Examples
```julia
julia> rand(Counts(Fill(Categorical([1/6, 2/6, 3/6]), 600)))
Dict{Int64,Int64} with 3 entries:
  2 => 193
  3 => 306
  1 => 101
```
"""
struct Counts{T,X} <: Distribution{Dict{T,Int}}
    x::X

    Counts(x::X) where {X} = new{eltype(gentype(x)),X}(x)
end

Sampler(::Type{RNG}, c::Counts, n::Repetition) where {RNG<:AbstractRNG} =
    SamplerTag{typeof(c)}(Sampler(RNG, c.x, n))

reset!(sp::SamplerTag{<:Counts}, n...) = (reset!(sp.data, n...); sp)

function rand(rng::AbstractRNG, sp::SamplerTag{<:Counts{T}}) where T
    dict = Dict{T,Int}()
    for x in rand(rng, sp.data)
        dict[x] = get(dict, x, 0) + 1
    end
    dict
end

"""
    counts(x, [n::Integer])

Equivalent to `rand(Counts(x))`, or to `rand(Counts(Fill(x, n)))`
when `n` is specified.

!!! warning
    Experimental function.
"""
counts(x) = rand(Counts(x))
counts(x, n) = rand(Counts(Fill(x, n)))


## Unique

struct Unique{T,X} <: Distribution{T}
    x::X

    Unique(x::X) where {X} = new{gentype(x),X}(x)
end

Unique(::Type{X}) where {X} = Unique(Uniform(X))

Sampler(RNG::Type{<:AbstractRNG}, u::Unique, n::Val{1}) =
    Sampler(RNG, u.x, n)

Sampler(RNG::Type{<:AbstractRNG}, u::Unique, n::Val{Inf}) =
    SamplerTag{typeof(u)}((x    = Sampler(RNG, u.x, n),
                           seen = Set{gentype(u)}()))

function reset!(sp::SamplerTag{<:Unique}, n=0)
    seen = sp.data.seen
    n > length(seen) && sizehint!(seen, n)
    empty!(seen)
    sp
end

function rand(rng::AbstractRNG, sp::SamplerTag{<:Unique})
    seen = sp.data.seen
    while true
        x = rand(rng, sp.data.x)
        x in seen && continue
        push!(seen, x)
        return x
    end
end


## Fisher-Yates

struct FisherYates{T,N,A} <: Distribution{T}
    a::A

    FisherYates(a::AbstractArray{T,N}) where {T,N} =
        new{T,N,typeof(a)}(a)
end

Sampler(::Type{RNG}, fy::FisherYates, ::Repetition) where {RNG<:AbstractRNG} =
    reset!(SamplerSimple(fy, Vector{Int}(undef, length(fy.a) + 1)))

function reset!(sp::SamplerSimple{<:FisherYates}, n=length(sp[].a))
    @inbounds sp.data[end] = -n # < 0 means not yet initialized
    sp
end

@noinline function fy_initialize!(rng, inds, k)
    k == 0 &&
        throw(ArgumentError("FisherYates: all elements have been consumed"))
    n = length(inds) - 1
    copyto!(inds, 1:n)
    m = n + k
    mask = nextpow(2, n) - 1
    while n != m
        (mask >> 1) == n && (mask >>= 1)
        i = 1 + rand(rng, Random.ltm52(n, mask))
        #^^^ faster equivalent to i = rand(rng, 1:n) (cf. Base.shuffle!)
        @inbounds inds[i], inds[n] = inds[n], inds[i]
        n -= 1
    end
end

function rand(rng::AbstractRNG, sp::SamplerSimple{<:FisherYates})
    inds = sp.data
    @inbounds begin
        k = inds[end] # contains the index in inds where the index in sp[].a is located
        if k <= 0
            fy_initialize!(rng, inds, k)
            k = -k
        end
        inds[end] = k - 1
        sp[].a[inds[k]]
    end
end


## SelfAvoid

# cf. `self_avoid_sample!` in StatsBase.jl

struct SelfAvoid{T,N,A} <: Distribution{T}
    a::A

    SelfAvoid(a::AbstractArray{T,N}) where {T,N} =
        new{T,N,typeof(a)}(a)
end

Sampler(RNG::Type{<:AbstractRNG}, sa::SelfAvoid, ::Repetition) =
    SamplerSimple(sa, (seen = Set{Int}(),
                       idx  = Sampler(RNG, Base.OneTo(length(sa.a)), Val(Inf))))

reset!(sp::SamplerSimple{<:SelfAvoid}, _=0) = (empty!(sp.data.seen); sp)

function rand(rng::AbstractRNG, sp::SamplerSimple{<:SelfAvoid{T}})::T where T
    seen = sp.data.seen
    idx = sp.data.idx
    while true
        i = rand(rng, idx)
        if !(i in seen)
            push!(seen, i)
            return @inbounds sp[].a[i]
        end
    end
end
