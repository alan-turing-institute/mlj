const SupervisedNetwork = Union{DeterministicNetwork,ProbabilisticNetwork}

# to suppress inclusion in models():
MLJBase.is_wrapper(::Type{DeterministicNetwork}) = true
MLJBase.is_wrapper(::Type{ProbabilisticNetwork}) = true

# fall-back for updating learning networks exported as models:
function MLJBase.update(model::SupervisedNetwork, verbosity, fitresult, cache, args...)
    fit!(fitresult; verbosity=verbosity)
    return fitresult, cache, nothing
end

# fall-back for predicting on learning networks exported as models
MLJBase.predict(composite::SupervisedNetwork, fitresult, Xnew) =
    fitresult(Xnew)

"""
    MLJ.tree(N::Node)

Return a tree-like summary of the learning network terminating at node
`N`.

"""
tree(s::MLJ.Source) = (source = s,)
function tree(W::MLJ.Node)
    mach = W.machine
    if mach == nothing
        value2 = nothing
        endkeys=[]
        endvalues=[]
    else
        value2 = mach.model        
        endkeys = [Symbol("train_arg", i) for i in eachindex(mach.args)]
        endvalues = [tree(arg) for arg in mach.args]
    end
    keys = tuple(:operation,  :model,
                 [Symbol("arg", i) for i in eachindex(W.args)]...,
                 endkeys...)
    values = tuple(W.operation, value2,
                   [tree(arg) for arg in W.args]...,
                   endvalues...)
    return NamedTuple{keys}(values)
end

# similar to tree but returns arguments as vectors, rather than individually
tree2(s::MLJ.Source) = (source = s,)
function tree2(W::MLJ.Node)
    mach = W.machine
    if mach == nothing
        value2 = nothing
        endvalue=[]
    else
        value2 = mach.model        
        endvalue = Any[tree2(arg) for arg in mach.args]
    end
    keys = tuple(:operation,  :model, :args, :train_args)
    values = tuple(W.operation, value2,
                   Any[tree(arg) for arg in W.args],
                   endvalue)
    return NamedTuple{keys}(values)
end

"""
    replace(W::MLJ.Node, a1=>b1, a2=>b2, ....)

Create a deep copy of a node `W`, and whence replicate the learning
network terminating at `W`, but replace any specified sources and
models `a1, a2, ...` of the original network by the specified targets
`b1, b2, ...`.

"""

function Base.replace(W::Node, pairs...)
end

# get the top level args of the tree of some node:
function args(tree) 
    keys_ = filter(keys(tree) |> collect) do key
        match(r"^arg[0-9]*", string(key)) != nothing
    end
    return (getproperty(tree, key) for key in keys_)
end
        
# get the top level train_args of the tree of some node:
function train_args(tree) 
    keys_ = filter(keys(tree) |> collect) do key
        match(r"^train_arg[0-9]*", string(key)) != nothing
    end
    return (getproperty(tree, key) for key in keys_)
end    

"""
    MLJ.reconstruct(tree)

Reconstruct a `Node` from its tree representation.

See also MLJ.tree

"""
function reconstruct(tree)
    if length(tree) == 1
        return first(tree)
    end
    values_ = values(tree)
    operation, model = values_[1], values_[2] 
    if model == nothing
        return node(operation, [reconstruct(arg) for arg in args(tree)]...)
    end
    mach = machine(model, [reconstruct(arg) for arg in train_args(tree)]...)
    return operation(mach, [reconstruct(arg) for arg in args(tree)]...)
end
        
"""

    models(N::AbstractNode)

A vector of all models referenced by node `N`, each model
appearing exactly once.

"""
function models(W::MLJ.AbstractNode)
    models_ = filter(MLJ.flat_values(tree(W)) |> collect) do model
        model isa MLJ.Model
    end
    return unique(models_)
end

"""
   allsources(N::AbstractNode)

A vector of all sources referenced by calls `N()` and `fit!(N)`. These
are the sources of the directed acyclic graph associated with the
learning network terminating at `N`, including all edges corresponding
to training data flow.

"""
function allsources(W::MLJ.AbstractNode)
    sources_ = filter(MLJ.flat_values(tree(W)) |> collect) do model
        model isa MLJ.Source
    end
    return unique(sources_)
end

"""
    reset!(N::Node)

Place the learning network terminating at node `N` into a state in
which `fit!(N)` will retrain from scratch all machines in its dependency
tape. Does not actually train any machine or alter fit-results.

"""
function reset!(W::Node)
    for mach in W.tape
        mach.state = 0
    end
end

# create a deep copy of the node N, with its sources stripped of
# content (data set to nothing):
function stripped_copy(N)
    sources = allsources(N)
    X = sources[1].data
    y = sources[2].data
    sources[1].data = nothing
    sources[1].data = nothing
    
    Ncopy = deepcopy(N)
    
    # restore data:
    sources[1].data = X
    sources[2].data = y

    return Ncopy
end

# returns a fit method having node N as blueprint
function fit_method(N::Node)

    function fit(::Any, verbosity, X, y)
        yhat = MLJ.stripped_copy(N)
        X_, y_ = MLJ.allsources(yhat)
        X_.data = X
        y_.data = y
        MLJ.reset!(yhat)
        fit!(yhat, verbosity=verbosity)
        cache = nothing
        report = nothing
        return yhat, cache, report
    end

    return fit
end
        
"""

   @composite NewCompositeModel(model1, model2, ...) <= N

Create a new stand-alone model type `NewCompositeModel` using the
learning network terminating at node `N` as a blueprint, equipping the
new type with field names `model1`, `model2`, ... . These fields point
to the component models in a deep copy of `N` that is created when an
instance of `NewCompositeModel` is first trained (ie, when `fit!` is
called on a machine binding the model to data). The counterparts of
these components in the original network `N` are the models
returned by `models(N)`, deep copies of which also serve as default
values for an automatically generated keywork constructor for
`NewCompositeModel`.

Return value: A new `NewCompositeModel` instance, with the default
field values detailed above. 

For details and examples refer to the "Learning Networks" section of
the documentation.

"""
macro composite(ex)
    modeltype_ex = ex.args[2].args[1]
    fieldname_exs = ex.args[2].args[2:end]
    N_ex = ex.args[3]
    composite_(__module__, modeltype_ex, fieldname_exs, N_ex)
    esc(quote
        $modeltype_ex()
        end)
end

function composite_(mod, modeltype_ex, fieldname_exs, N_ex)


    N = mod.eval(N_ex)
    N isa Node ||
        error("$(typeof(N)) bgiven where Node was expected. ")

    if models(N)[1] isa Supervised

        if MLJBase.is_probabilistic(typeof(models(N)[1]))
            subtype_ex = :ProbabilisticNetwork
        else
            subtype_ex = :DeterministicNetwork
        end

        # code defining the composite model struct and fit method:
        program1 = quote

            import MLJBase

            mutable struct $modeltype_ex <: MLJ.$subtype_ex
               $(fieldname_exs...)
            end

            MLJBase.fit(model::$modeltype_ex,
                        verbosity::Integer, X, y) =
                            MLJ.fit_method($N_ex)(model, verbosity, X, y)
        end

        program2 = quote
            MLJBase.@set_defaults($modeltype_ex,
                             MLJ.models(MLJ.stripped_copy(($N_ex))))
        end

        mod.eval(program1)   
        mod.eval(program2)
    else
        @warn "Did nothing"
    end

end


## A COMPOSITE FOR TESTING PURPOSES

"""
    SimpleDeterministicCompositeModel(;regressor=ConstantRegressor(), 
                              transformer=FeatureSelector())

Construct a composite model consisting of a transformer
(`Unsupervised` model) followed by a `Deterministic` model. Mainly
intended for internal testing .

"""
mutable struct SimpleDeterministicCompositeModel{L<:Deterministic,
                             T<:Unsupervised} <: DeterministicNetwork
    model::L
    transformer::T
    
end

function SimpleDeterministicCompositeModel(; model=DeterministicConstantRegressor(), 
                          transformer=FeatureSelector())

    composite =  SimpleDeterministicCompositeModel(model, transformer)

    message = MLJ.clean!(composite)
    isempty(message) || @warn message

    return composite

end

MLJBase.is_wrapper(::Type{<:SimpleDeterministicCompositeModel}) = true

function MLJBase.fit(composite::SimpleDeterministicCompositeModel, verbosity::Int, Xtrain, ytrain)
    X = source(Xtrain) # instantiates a source node
    y = source(ytrain)

    t = machine(composite.transformer, X)
    Xt = transform(t, X)

    l = machine(composite.model, Xt, y)
    yhat = predict(l, Xt)

    fit!(yhat, verbosity=verbosity)
    fitresult = yhat
    report = l.report
    cache = l
    return fitresult, cache, report
end

# MLJBase.predict(composite::SimpleDeterministicCompositeModel, fitresult, Xnew) = fitresult(Xnew)

MLJBase.load_path(::Type{<:SimpleDeterministicCompositeModel}) = "MLJ.SimpleDeterministicCompositeModel"
MLJBase.package_name(::Type{<:SimpleDeterministicCompositeModel}) = "MLJ"
MLJBase.package_uuid(::Type{<:SimpleDeterministicCompositeModel}) = ""
MLJBase.package_url(::Type{<:SimpleDeterministicCompositeModel}) = "https://github.com/alan-turing-institute/MLJ.jl"
MLJBase.is_pure_julia(::Type{<:SimpleDeterministicCompositeModel}) = true
# MLJBase.input_scitype_union(::Type{<:SimpleDeterministicCompositeModel}) = 
# MLJBase.target_scitype_union(::Type{<:SimpleDeterministicCompositeModel}) = 
