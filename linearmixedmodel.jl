abstract LinearMixedModel <: MixedModel

function lmer(f::Formula, df::AbstractDataFrame)
    mf = ModelFrame(f, df)
    mm = ModelMatrix(mf)
    re = retrms(mf)
    if length(re) == 0 error("No random-effects terms were specified") end
    resp = dv(model_response(mf))
    if length(re) == 1
        return issimple(re[1]) ?
        ScalarLMM1(mm.m, grpfac(re[1], mf), resp) :
        VectorLMM1(mm.m', grpfac(re[1], mf), lhs(re[1],mf).m', resp)
    end
    if !issimple(re) error("only simple random-effects terms allowed") end 
    LMMsplit(grpfac(re,mf), mm.m, resp)
end
lmer(ex::Expr, df::AbstractDataFrame) = lmer(Formula(ex), df)

## Optimization of objective using BOBYQA
## According to convention the name should be fit! as this is a
## mutating function but I figure fit is obviously mutating and I
## wanted to piggy-back on the fit generic created in Distributions
function fit(m::LinearMixedModel, verbose::Bool)
    if !isfit(m)
        k = length(thvec!(m))
        opt = Opt(:LN_BOBYQA, k)
        ftol_abs!(opt, 1e-6)    # criterion on deviance changes
        xtol_abs!(opt, 1e-6)    # criterion on all parameter value changes
        lower_bounds!(opt, lower!(m))
        function obj(x::Vector{Float64}, g::Vector{Float64})
            if length(g) > 0 error("gradient evaluations are not provided") end
            objective!(m, x)
        end
        if verbose
            count = 0
            function vobj(x::Vector{Float64}, g::Vector{Float64})
                if length(g) > 0 error("gradient evaluations are not provided") end
                count += 1
                val = obj(x, g)
                println("f_$count: $val, $x")
                val
            end
            min_objective!(opt, vobj)
        else
            min_objective!(opt, obj)
        end
        fmin, xmin, ret = optimize(opt, thvec!(m))
        if verbose println(ret) end
        setfit!(m)
    end
    m
end
fit(m::LinearMixedModel) = fit(m, false)      # non-verbose

## A type for a linear mixed model should provide, directly or
## indirectly, methods for:
##  obs!(m) -> *reference to* the observed response vector
##  exptd!(m) -> *reference to* mean response vector at current parameter values
##  sqrtwts!(m) -> *reference to* square roots of the case weights if used, can be of
##      length 0, *not copied*
##  L(m) -> a vector of matrix representations that together provide
##      the Cholesky factor of the random-effects part of the system matrix
##  wrss(m) -> weighted residual sum of squares
##  pwrss(m) -> penalized weighted residual sum of squares
##  Zt!(m) -> an RSC matrix representation of the transpose of Z - can be a reference
##  size(m) -> n, p, q, t (lengths of y, beta, u and # of re terms)
##  X!(x) -> a reference to the fixed-effects model matrix
##  RX!(x) -> a reference to a Cholesky factor of the downdated X'X
##  isfit(m) -> Bool - Has the model been fit?
##  lower!(m) -> *reference to* the vector of lower bounds on the theta parameters
##  thvec!(m) -> current theta as a vector - can be a reference
##  fixef!(m) -> value of betahat - the model is fit before extraction
##  ranef!(m) -> conditional modes of the random effects
##  setfit!(m) -> set the boolean indicator of the model having been
##     fit; returns m
##  uvec(m) -> a reference to the current conditional means of the
##     spherical random effects. Unlike a call to ranef or fixef, a
##     call to uvec does not cause the model to be fit.
##  reml!(m) -> set the REML flag and clear the fit flag; returns m
##  objective!(m, thv) -> set a new value of the theta vector; update
##     beta, u and mu; return the objective (deviance or REML criterion)
##  grplevels(m) -> a vector giving the number of levels in the
##     grouping factor for each re term.
##  VarCorr!(m) -> a vector of estimated variance-covariance matrices
##     for each re term and for the residuals - can trigger a fit

## Default implementations
function wrss(m::LinearMixedModel)
    y = obs!(m); mu = exptd!(m); wt = sqrtwts!(m)
    w = bool(length(sqrtwts!(m)))
    s = zero(eltype(y))
    for i in 1:length(y)
        r = y[i] - mu[i]
        if w r /= sqrtwts[i] end
        s += r * r
    end
    s
end
pwrss(m::LinearMixedModel) = (s = wrss(m);for u in uvec!(m) s += u*u end; s)
setfit!(m::LinearMixedModel) = (m.fit = true; m)
unsetfit!(m::LinearMixedModel) = (m.fit = false; m)
setreml!(m::LinearMixedModel) = (m.REML = true; m.fit = false; m)
unsetreml!(m::LinearMixedModel) = (m.REML = false; m.fit = false; m)
obs!(m::LinearMixedModel) = m.y
fixef!(m::LinearMixedModel) = fit(m).beta
isfit(m::LinearMixedModel) = m.fit
isreml(m::LinearMixedModel) = m.fit
lower!(m::LinearMixedModel) = m.lower
thvec!(m::LinearMixedModel) = m.theta
exptd!(m::LinearMixedModel) = m.mu
uvec!(m::LinearMixedModel) = m.u

deviance(m::LinearMixedModel) = (unsetreml!(m); fit(m); objective(m, thvec!(m)))
reml(m::LinearMixedModel) = (setreml!(m); fit(unsetfit!(m)); objective(m, thvec!(m)))

function show(io::IO, m::LinearMixedModel)
    fit(m)
    REML = m.REML
    criterionstr = REML ? "REML" : "maximum likelihood"
    println(io, "Linear mixed model fit by $criterionstr")
    oo = objective(m)
    if REML
        println(io, " REML criterion: $oo")
    else
        println(io, " logLik: $(-oo/2), deviance: $oo")
    end
    vc = VarCorr(m)
    println("\n  Variance components: $vc")
    n, p, q = size(m)
    println("  Number of obs: $n; levels of grouping factors: $(grplevs(m))")
    println("  Fixed-effects parameters: $(fixef(m))")
end

abstract ScalarLinearMixedModel <: LinearMixedModel

function VarCorr(m::ScalarLinearMixedModel)
    fit(m)
    n, p, q = size(m)
    [m.theta .^ 2, 1.] * (pwrss(m)/float(n - (m.REML ? p : 0)))
end

function grplevs(m::ScalarLinearMixedModel)
    rv = m.Zt.rowval
    [length(unique(rv[i,:]))::Int for i in 1:size(rv,1)]
end

## Check validity and install a new value of theta;
##  update lambda, A
## function installtheta(m::SimpleLinearMixedModel, theta::Vector{Float64})
##     n, p, q = size(m)
##     if length(theta) != length(m.theta) error("Dimension mismatch") end
##     if any(theta .< m.lower)
##         error("theta = $theta violates lower bounds $(m.lower)")
##     end
##     m.theta[:] = theta[:]               # copy in place
##     for i in 1:length(theta)            # update Lambda (stored as a vector)
##         fill!(m.lambda, theta[i], int(m.Zt.rowrange[i]))
##     end
## end
