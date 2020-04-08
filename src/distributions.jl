## Bernoulli

struct Bernoulli{T<:Number} <: Distribution{T}
    p::Float64

    Bernoulli{T}(p::Real) where {T} = let pf = Float64(p)
        0.0 <= pf <= 1.0 ? new(pf) :
            throw(DomainError(p, "Bernoulli: parameter p must satisfy 0.0 <= p <= 1.0"))
    end
end

Bernoulli(p::Real=0.5) = Bernoulli(Bool, p)
Bernoulli(::Type{T}, p::Real=0.5) where {T<:Number} = Bernoulli{T}(p)


### sampling

Sampler(RNG::Type{<:AbstractRNG}, b::Bernoulli, n::Repetition) =
    SamplerTag{typeof(b)}(b.p+1.0)

rand(rng::AbstractRNG, sp::SamplerTag{Bernoulli{T}}) where {T} =
    ifelse(rand(rng, CloseOpen12()) < sp.data, one(T), zero(T))


## Binomial

struct Binomial <: Distribution{Int}
    n::Int
    p::Float64

    Binomial(n::Integer=1, p::Real=0.5) =
        0.0 <= p <= 1.0 ? new(n, p) :
            throw(DomainError(p, "Binomial: parameter p must satisfy 0.0 <= p <= 1.0"))
end


## sampling

Sampler(RNG::Type{<:AbstractRNG}, b::Binomial, ::Repetition) =
    SamplerTag{Binomial}((n  = b.n,
                          p  = b.p + 1.0,
                          sp = Sampler(RNG, CloseOpen12(), Val(Inf))))

# TODO: implement non-naïve algo
rand(rng::AbstractRNG, sp::SamplerTag{Binomial}) =
    count(x -> x < sp.data.p,
          (rand(rng, sp.data.sp) for _ = 1:sp.data.n))


## Categorical ###############################################################

struct Categorical{T,A,VF} <: Distribution{T}
    components::A
    cdf::VF

    # raw constructor
    global _Categorical(::Type{T}, cdf, components) where {T} =
        new{T,typeof(components),typeof(cdf)}(components, cdf)

    function Categorical(n::Number, components=nothing) # equal weigths
        if components === nothing
            components = Base.OneTo(Int(n))
        else
            Base.require_one_based_indexing(components)
        end
        new{eltype(components),typeof(components),Nothing}(components,
                                                           nothing)
    end

    function Categorical(weigths, components=nothing)
        if !isa(weigths, AbstractArray)
            # necessary for accumulate
            # TODO: will not be necessary anymore in Julia 1.5
            weigths = collect(weigths)
        end
        weigths = vec(weigths)

        isempty(weigths) &&
            throw(ArgumentError("Categorical requires at least one category"))

        if components === nothing
            components = Base.OneTo(length(weigths))
        else
            Base.require_one_based_indexing(components)
        end

        length(components) == length(weigths) || throw(ArgumentError(
            "components and weigths must have the same length"))

        s = Float64(sum(weigths))
        cdf = accumulate(weigths; init=0.0) do x, y
            x + Float64(y) / s
        end
        @assert isapprox(cdf[end], 1.0) # really?
        cdf[end] = 1.0 # to be sure the algo terminates
        new{eltype(components),typeof(components),Vector{Float64}}(
            components, cdf)
    end
end

ncategories(c::Categorical) = length(c.components)

# unfortunately requires @inline to avoid allocating
@inline rand(rng::AbstractRNG, sp::SamplerTrivial{<:Categorical}) =
    let c = rand(rng, CloseOpen())
        @inbounds sp[].components[findfirst(x -> x >= c, sp[].cdf)]
    end

# NOTE:
# if length(cdf) is somewhere between 150 and 200, the following gets faster:
#   T(searchsortedfirst(sp[].cdf, rand(rng, sp.data)))

Sampler(::Type{RNG}, c::Categorical{T,A,Nothing},
        n::Repetition) where {RNG<:AbstractRNG,T,A} =
    SamplerTag{typeof(c)}(Sampler(RNG, c.components, n))

rand(rng::AbstractRNG, sp::SamplerTag{<:Categorical}) =
    rand(rng, sp.data)


## Multinomial ###############################################################

struct Multinomial{C<:Categorical{Int,Base.OneTo{Int}}} <: Distribution{Vector{Int}}
    cat::C
    n::Int
end

variate_size(m::Multinomial) = (ncategories(m.cat),)

Sampler(RNG::Type{<:AbstractRNG}, m::Multinomial, n::Repetition) =
    SamplerTag{typeof(m)}((cat  = Sampler(RNG, m.cat, n),
                           # sampler cat doesn't necessary save ncat:
                           ncat = ncategories(m.cat),
                           n    = m.n))

function rand!(rng::AbstractRNG, A::AbstractArray{<:Number},
               sp::SamplerTag{<:Multinomial}, ::Val{1})
    Base.require_one_based_indexing(A)
    cat = sp.data.cat
    sp.data.ncat != length(A) && resize!(A, sp.data.ncat)
    fill!(A, 0)
    for i = 1:sp.data.n
        @inbounds A[rand(rng, cat)] += 1
    end
    A
end

rand(rng::AbstractRNG, sp::SamplerTag{<:Multinomial}) =
    rand!(rng, Vector{Int}(undef, sp.data.ncat), sp, Val(1))


## Mixture Model #############################################################

struct MixtureModel{T,C} <: Distribution{T}
    cat::C

    MixtureModel{T}(cat::Categorical) where {T} = new{T,typeof(cat)}(cat)
end

MixtureModel(cat::Categorical) = MixtureModel{gentype(eltype(cat))}(cat)

function MixtureModel(weigths, components)
    components = map(wrap, components)
    T = reduce(typejoin, (gentype(x) for x in components))
    MixtureModel{T}(Categorical(weigths, components))
end


@inline Sampler(::Type{RNG}, m::MixtureModel,
                n::Val{1}) where {RNG<:AbstractRNG} =
    SamplerTag{typeof(m)}(Sampler(RNG, m.cat, n))

# WARNING: expensive, for less than 100 number generations or so,
# use Val(1) Sampler
Sampler(::Type{RNG}, m::MixtureModel{T},
        n::Val{Inf}) where {RNG<:AbstractRNG,T} =
    SamplerTag{typeof(m)}(
        Sampler(RNG,
                _Categorical(T, m.cat.cdf,
                             map(c -> Sampler(RNG, c, n), m.cat.components)),
                n))

@inline rand(rng::AbstractRNG, sp::SamplerTag{<:MixtureModel}) =
    rand(rng, rand(rng, sp.data))::gentype(sp)


## Normal ####################################################################

abstract type Normal{T} <: Distribution{T} end

struct Normal01{T} <: Normal{T} end

struct Normalμσ{T} <: Normal{T}
    μ::T
    σ::T
end

const NormalTypes = Union{AbstractFloat,Complex{<:AbstractFloat}}

Normal(::Type{T}=Float64) where {T<:NormalTypes} = Normal01{T}()
Normal(μ::T, σ::T) where {T<:NormalTypes} = Normalμσ(μ, σ)
Normal(μ::T, σ::T) where {T<:Real} = Normalμσ(AbstractFloat(μ), AbstractFloat(σ))
Normal(μ, σ) = Normal(promote(μ, σ)...)


### sampling

rand(rng::AbstractRNG, ::SamplerTrivial{Normal01{T}}) where {T<:NormalTypes} =
    randn(rng, T)

Sampler(RNG::Type{<:AbstractRNG}, d::Normalμσ{T}, n::Repetition) where {T} =
    SamplerSimple(d, Sampler(RNG, Normal(T), n))

rand(rng::AbstractRNG, sp::SamplerSimple{Normalμσ{T},<:Sampler}) where {T} =
    sp[].μ + sp[].σ  * rand(rng, sp.data)


## Exponential

abstract type Exponential{T} <: Distribution{T} end

struct Exponential1{T} <: Exponential{T} end

struct Exponentialθ{T} <: Exponential{T}
    θ::T
end

Exponential(::Type{T}=Float64) where {T<:AbstractFloat} = Exponential1{T}()
Exponential(θ::T) where {T<:AbstractFloat} = Exponentialθ(θ)
Exponential(θ::Real) = Exponentialθ(AbstractFloat(θ))


### sampling

rand(rng::AbstractRNG, ::SamplerTrivial{Exponential1{T}}) where {T<:AbstractFloat} =
    randexp(rng, T)

Sampler(RNG::Type{<:AbstractRNG}, d::Exponentialθ{T}, n::Repetition) where {T} =
    SamplerSimple(d, Sampler(RNG, Exponential(T), n))

rand(rng::AbstractRNG, sp::SamplerSimple{Exponentialθ{T},<:Sampler}) where {T} =
    sp[].θ * rand(rng, sp.data)


## Poisson

struct Poisson <: Distribution{Int}
    λ::Float64

    function Poisson(λ::Real=1.0)
        λ < 0.0 && throw(ArgumentError("Poisson: parameter λ must be non-negative"))
        new(λ)
    end
end

function rand(rng::AbstractRNG, sp::SamplerTrivial{Poisson})
    λ = sp[].λ
    exponential = Sampler(rng, Exponential())
    s = rand(rng, exponential)
    x = 0
    while s < λ
        s += rand(rng, exponential)
        x += 1
    end
    x
end
