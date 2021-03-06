using Distributions
import Distributions: mean, var, cov, rand

abstract AbstractStateSpaceModel
typealias AbstractSSM AbstractStateSpaceModel
abstract AbstractGaussianSSM <: AbstractStateSpaceModel
abstract AbstractLinearGaussian <: AbstractGaussianSSM

"""
Data structure representing the estimated state of a state-space model
after filtering/smoothing.

#### Fields
- observations : Array of observations. Each column is  a single observation vector.
- state : Array of (possibly multivariate) Distributions. Each distribution
represents the estimate and uncertainty of the hidden state at that time.
- loglik : The log-likelihood of the model, i.e. the probabilty of the observations
given the model and state estimates.
"""
type FilteredState{T, D<:ContinuousMultivariateDistribution}
	observations::Array{T, 2}
	state::Array{D}
	loglik::T
end

typealias SmoothedState FilteredState

function show{T}(io::IO, fs::FilteredState{T})
	n = length(fs.state)
	dobs = size(fs.observations, 1)
	dstate = length(fs.state[1])
	println("FilteredState{$T}")
	println("$n estimates of $dstate-D process from $dobs-D observations")
	println("Log-likelihood: $(fs.loglik)")
end

function show{T}(io::IO, fs::SmoothedState{T})
	n = length(fs.state)
	dobs = size(fs.observations, 1)
	dstate = length(fs.state[1])
	println("SmoothedState{$T}")
	println("$n estimates of $dstate-D process from $dobs-D observations")
	println("Log-likelihood: $(fs.loglik)")
end

"""
Returns the log-likelihood of the FilteredState object.
"""
loglikelihood(fs::FilteredState) = fs.loglik

for op in (:mean, :var, :cov, :cor, :rand)
	@eval begin
		function ($op){T}(s::FilteredState{T})
			result = Array(T, length(s.state[1]), length(s.state))
			for i in 1:length(s.state)
				result[:, i] = ($op)(s.state[i])
			end
			return result
		end
	end
end

"""
Forecast the state of the process at the next time step.

#### Parameters
- m : AbstractGaussianSSM.  Model of the state evolution and observation processes.
- x : AbstractMvNormal.  Current state estimate.

#### Returns
- MvNormal distribution representing the forecast and its associated uncertainty.
"""
function predict(m::AbstractGaussianSSM, x::AbstractMvNormal)
	F = process_matrix(m, x)
	return MvNormal(F * mean(x), F * cov(x) * F' + m.V)
end

"""
Observe the state process with uncertainty.

#### Parameters
- m : AbstractGaussianSSM.  Model of the state evolution and observation processes.
- x : AbstractMvNormal.  Current state estimate.

#### Returns
- MvNormal distribution, representing the probability of recording any
particular observation data.
"""
function observe(m::AbstractGaussianSSM, x::AbstractMvNormal)
	G = observation_matrix(m, x)
	return MvNormal(G * mean(x), G * cov(x) * G' + m.W)
end

function observe(m::AbstractGaussianSSM, x::AbstractMvNormal, meas_cov::Matrix)
	G = observation_matrix(m, x)
	return MvNormal(G * mean(x), G * cov(x) * G' + meas_cov)
end

"""
NEED TO ADD DOCUMENTATION HERE
"""
function innovate(m::AbstractGaussianSSM, pred::AbstractMvNormal, y_pred::AbstractMvNormal, y)
    G = observation_matrix(m, pred)
	innovation = y - mean(y_pred)
	innovation_cov = cov(y_pred)
	K = cov(pred) * G' * inv(innovation_cov)
	mean_update = mean(pred) + K * innovation
	cov_update = (eye(cov(pred)) - K * G) * cov(pred)
	return MvNormal(mean_update, cov_update)
end

"""
Refine a forecast state based on a new observation.

#### Parameters
- m : AbstractGaussianSSM.  Model of the state evolution and observation processes.
- pred : AbstractMvNormal.  Estimate of state at time t, given data up to t-1.
- y : Vector of the latest observation at time t.

#### Returns
- MvNormal distribution, representing the estimate of the state at time t given
all data up to t.
"""
function update(m::AbstractGaussianSSM, pred::AbstractMvNormal, y)
    y_pred = observe(m, pred)
    return innovate(m, pred, y_pred, y)
end

function update(m::AbstractGaussianSSM, pred::AbstractMvNormal, y::Vector, meas_cov::Matrix)
    y_pred = observe(m, pred, meas_cov)
    return innovate(m, pred, y_pred, y)
end


"""
Extend a FilteredState 'on-line' when a new observation becomes available.
This function enlarges the FilteredState, so may not be a good choice for
applications where many new observations have to be assimilated very fast.

#### Parameters
- m : AbstractGaussianSSM.  Model of the state evolution and observation processes.
- fs : A FilteredState object.
- y : Vector of the latest observation at time t.

#### Returns
- fs : The FilteredState, extended with one more observation and state estimate.
"""
function update!(m::AbstractGaussianSSM, fs::FilteredState, y)
	x_pred = predict(m, fs.state[end])
	x_filt = update(m, x_pred, y)
	push!(fs.state, x_filt)
	fs.observations = [fs.observations y]
	return fs
end

"""
Given a process/observation model and a set of data, estimate the states of the
hidden process at each time step.

#### Parameters
- m : AbstractGaussianSSM.  Model of the state evolution and observation processes.
- y : Array of data.  Each column is a set of observations at one time, while
each row is one observed variable.  Can contain NaNs to represent missing data.
- x0 : AbstractMvNorm. Multivariate normal distribution representing our estimate
of the hidden state and our uncertainty about that estimate before our first observation.
(i.e., if the first data arrives at t=1, this is where we think the process is at t=0.)

#### Returns
- A FilteredState object holding the estimates of the hidden state.

#### Notes
This function only does forward-pass filtering--that is, the state estimate at time
t incorporates data from 1:t, but not from t+1:T.  For full forward-and-backward
filtering, run `smooth` on the FilteredState produced by this function.
"""
function filter{T}(m::AbstractGaussianSSM, y::Array{T}, x0::AbstractMvNormal, estMissObs::Bool=false)
	x_filtered = Array(AbstractMvNormal, size(y, 2) + 1)
	x_filtered[1] = x0
    y_obs = zeros(y)
    loglik = 0.0
    for i in 1:size(y, 2)
        y_current = y[:, i]
        x_pred = predict(m, x_filtered[i])
        y_pred = observe(m, x_pred)
        # Check for missing values in observation
        y_Boolean = isnan(y_current)
        if any(y_Boolean)
            if estMissObs
                y_current, y_cov_mat = estimateMissingObs(m, x_pred, y_pred, y_current, y_Boolean)
                x_filtered[i+1] = update(m, x_pred, y_current, y_cov_mat)
                loglik += logpdf(observe(m, x_filtered[i+1]), y_current)
            else
                x_filtered[i+1] = x_pred
            end
        else
            x_filtered[i+1] = update(m, x_pred, y_current)
			loglik += logpdf(observe(m, x_filtered[i+1]), y_current)
        end
        if i != 1
            loglik += logpdf(x_pred, mean(x_filtered[i+1]))
        else
            loglik += logpdf(x_filtered[i+1], mean(x_pred))
        end
        y_obs[:,i] = y_current
    end
    return FilteredState(y_obs, x_filtered, loglik)
end

"""
Given a process/observation model and a set of data, estimate the states of the
hidden process at each time step using forward and backward passes.

This function has two methods.  It can take either an AbstractGaussianSSM and a the
FilteredState produced by a previous call to `filter`, or it can take a model, data,
set, and initial state estimate, in which case it does the forward and backward
passes at once.

"""
function smooth{T}(m::AbstractGaussianSSM, fs::FilteredState{T})
	n = size(fs.observations, 2)
	smooth_dist = Array(AbstractMvNormal, n)
	smooth_dist[end] = fs.state[end]
	loglik = logpdf(observe(m, smooth_dist[end]), fs.observations[:, end])
	for i in (n - 1):-1:1
		state_pred = predict(m, fs.state[i+1])
		P = cov(fs.state[i+1])
		F = process_matrix(m, fs.state[i+1])
		J = P * F' * inv(cov(state_pred))
		x_smooth = mean(fs.state[i+1]) + J *
			(mean(smooth_dist[i+1]) - mean(state_pred))
		P_smooth = P + J * (cov(smooth_dist[i+1]) - cov(state_pred)) * J'
		smooth_dist[i] = MvNormal(x_smooth, P_smooth)
		loglik += logpdf(predict(m, smooth_dist[i]), mean(smooth_dist[i+1]))
		if !any(isnan(fs.observations[:, i]))
			loglik += logpdf(observe(m, smooth_dist[i]), fs.observations[:, i])
		end
	end
	return SmoothedState(fs.observations, smooth_dist, loglik)
end

function smooth{T}(m::AbstractGaussianSSM, y::Array{T}, x0::AbstractMvNormal)
	fs = filter(m, y, x0)
	return smooth(m, fs)
end

"""
Simulate a realization of a state-space process and observations of it.

#### Parameters
- m : AbstractGaussianSSM.  Model of the state evolution and observation processes.
- x0 : AbstractMvNorm. Distribution of the state process's starting value.

#### Returns
- (x, y) : Tuple of the process and observation arrays.
"""
function simulate(m::AbstractGaussianSSM, n::Int64, x0::AbstractMvNormal)
	F = process_matrix(m, x0)
	G = observation_matrix(m, x0)
	x = zeros(size(F, 1), n)
	y = zeros(size(G, 1), n)
	x[:, 1] = rand(MvNormal(F * mean(x0), m.V))
	y[:, 1] = rand(MvNormal(G * x[:, 1], m.W))
	for i in 2:n
		F = process_matrix(m, x[:, i-1])
		G = observation_matrix(m, x[:, i-1])
		x[:, i] = F * x[:, i-1] + rand(MvNormal(m.V))
		y[:, i] = G * x[:, i] + rand(MvNormal(m.W))
	end
	return (x, y)
end

"""
Fit a state-space model to data using maximum likelihood.


"""
function fit(build_func, y, x0, params0, args...)

	function objective(params)
		ssm = build_func(params)
		return -loglikelihood(smooth(m, y, x0))
	end
	fit = optimize(objective, params0, args...)
end

function estimateMissingObs(m::AbstractSSM, x::AbstractMvNormal, y_pred::AbstractMvNormal, y::Vector, yBool::Vector{Bool})
    ##### Generate selector matrices #####
    #Preallocate Arrays
    numObs = length(y)
    S = eye(numObs)
    Sc = eye(numObs)
    yObs = Vector{typeof(NaN)}()
    #Loop through each observation
    for i in numObs:-1:1
        #If observation is an NaN value then remove the corresponding column of the selector matrix
        #otherwise remove the corresponding column of the compliment selector matrix and add observed value to yObs matrix
        if yBool[i]
            S = S[:, 1:size(S,2) .!= i]
        else
            Sc = Sc[:, 1:size(Sc,2) .!= i]
            push!(yObs, y[i])
        end
    end
    #Transpose the selector matrices
    S = S'
    Sc = Sc'
    yObs = reverse(yObs) #Reverse the observation vector to correct the order

    ##### Estimate missing Observations #####
    μ_yMiss = Sc*mean(y_pred)  + Sc*m.W*S' * inv(S*m.W*S') * (yObs - S*mean(y_pred))
    Σ_yMiss = Sc*m.W*Sc' - Sc*m.W*S' * inv(S*m.W*S') * S*m.W*Sc'

    ##### Reconstruct observation array and covariance matrix
    S_full = [S;Sc] #Concatenate selector matrices
    y_full = S_full' * [yObs; μ_yMiss] # Reconstruct Observation vector
    y_covFull = S_full' * [S*m.W; Σ_yMiss*Sc] # Reconstruct Observation covariance matrix

    #Ensure that the covariance matrix is symmetric
    for i in 1:numObs-1
        y_covFull[i+1:end, i] = y_covFull[i, i+1:end]
    end

    return y_full, y_covFull #Return estimated observation vector and the updated measurement error covariance matrix
end
