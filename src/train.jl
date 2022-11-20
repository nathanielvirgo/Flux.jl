module Train

using LinearAlgebra
using Optimisers: Optimisers
using Functors: fmap

import ..Flux.Optimise: train!, update!  # during 0.13, we add methods to the old functions

export setup, train!

using ProgressLogging: @progress, @withprogress, @logprogress
using Zygote: Zygote, Params

"""
    opt = setup(rule, model)

This is a version of `Optimisers.setup`, and is the first step before using [`train!`](@ref Flux.train!).
It differs from `Optimisers.setup` in that it:
* has one extra check for mutability (since Flux expects to mutate the model in-place,
  while Optimisers.jl is designed to return an updated model)
* has methods which accept Flux's old optimisers, and convert them.
  (The old `Flux.Optimise.Adam` and new `Optimisers.Adam` are distinct types.)

# Example
```jldoctest
julia> model = Dense(2=>1, leakyrelu; init=Flux.ones32);

julia> opt = Flux.setup(Momentum(0.1), model)  # this encodes the optimiser and its state
(weight = Leaf(Momentum{Float64}(0.1, 0.9), Float32[0.0 0.0]), bias = Leaf(Momentum{Float64}(0.1, 0.9), Float32[0.0]), σ = ())

julia> x1, y1 = [0.2, -0.3], [0.4];  # use the same data for two steps:

julia> Flux.train!(model, [(x1, y1), (x1, y1)], opt) do m, x, y
         sum(abs.(m(x) .- y)) * 100
       end

julia> model.bias  # was zero, mutated by Flux.train!
1-element Vector{Float32}:
 10.190001

julia> opt  # mutated by Flux.train!
(weight = Leaf(Momentum{Float64}(0.1, 0.9), Float32[-2.018 3.027]), bias = Leaf(Momentum{Float64}(0.1, 0.9), Float32[-10.09]), σ = ())
```
"""
function setup(rule::Optimisers.AbstractRule, model)
    state = Optimisers.setup(rule, model)
    fmap(model, exclude = Optimisers.isnumeric) do x
      Optimisers.maywrite(x) || error("""model must be fully mutable for `train!` to work, got `x::$(typeof(x))`.
                                         If `x .+= dx` is in fact ok, define `Optimisers.maywrite(::$(typeof(x))) = true`""")
    end
    state
end

"""
    train!(loss, model, data, opt)

Uses a `loss` function and training `data` to improve the `model`'s parameters
according to a particular optimisation rule `opt`. Iterates through `data` once,
evaluating `loss(model, d...)` for each `d` in data.

For example, with these definitions...
```
data = [(x1, y1), (x2, y2), (x3, y3)];  # each element must be a tuple

loss3(m, x, y) = norm(m(x) .- y)        # the model is the first argument

opt = Flux.setup(Adam(), model)         # explicit setup of optimiser momenta
```
...calling `Flux.train!(loss3, model, data, opt)` runs a loop much like this,
using Zygote's "explicit" mode for the gradient:
```
for d in data
    ∂L∂m = gradient(loss3, model, d...)[1]
    update!(opt, model, ∂L∂m)           # method for "explicit" gradient
end
```
You can also write this loop yourself, if you need more flexibility.
For this reason `train!` is not highly extensible.
It adds only a few featurs to the loop above:

* Stop with a `DomainError` if the loss is infinite or `NaN` at any point.

* Show a progress bar using [`@withprogress`](https://github.com/JuliaLogging/ProgressLogging.jl).

!!! note
    This method has significant changes from the one in Flux ≤ 0.13:
    * It now takes the `model` itself, not the result of [`Flux.params`](@ref).
      (This is to move away from Zygote's "implicit" parameter handling, with `Grads`.)
    * Instead of `loss` being a function which accepts only the data,
      now it must also accept the `model` itself, as the first argument.
    * `data` must iterate tuples, otherwise you get an error.
      (Previously non-tuple types were not splatted into the loss. 
      Pass in `((d,) for d in data)` to simulate this.)
    * `opt` should be the result of [`Flux.setup`](@ref). Using an optimiser
      such as `Adam()` without this step should give you a warning.
    * Callback functions are not supported.
      But any code can be included in the above `for` loop.
"""
function train!(loss, model, data, opt; cb = nothing)
  isnothing(cb) || error("""train! does not support callback functions.
                            For more control use a loop with `gradient` and `update!`.""")
  @withprogress for (i,d) in enumerate(data)
    d isa Tuple || error("""train! expects as data an iterator producing tuples, but got $(typeof(d)).
                            Pass it `((d,) for d in data)`, or use `gradient` and `update!` for more control.""")
    l, gs = Zygote.withgradient(m -> loss(m, d...), model)
    if !isfinite(l)
      throw(DomainError("Loss is $l on data item $i, stopping training"))
    end
    opt, model = Optimisers.update!(opt, model, gs[1])
    @logprogress Base.haslength(data) ? i/length(data) : nothing
  end
end

# This method let you use Optimisers.Descent() without setup, when there is no state
function train!(loss, model, data, rule::Optimisers.AbstractRule)
  train!(loss, model, data, _rule_to_state(model, rule))
end

function _rule_to_state(model, rule::Optimisers.AbstractRule)
  state = setup(rule, model)
  @gensym warn_id
  name = typeof(rule).name.name
  fmap(state, exclude = x -> x isa Optimisers.Leaf) do leaf
    leaf.state isa Nothing ||  @warn """Optimiser $name has state which will be discarded after `train!` finishes.
                                        Please run `opt = Flux.setup($name(), model)` and pass this `opt` to `train!`.""" leaf maxlog=1 _id=warn_id
    leaf
  end
  state
end

end # module Train