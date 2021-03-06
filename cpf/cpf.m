function [max_lambda, predicted_list, corrected_list, combined_list, success, et] = cpf(casedata, participation, sigmaForLambda, sigmaForVoltage, verbose, plotting, do_phase3)
%CPF  Run continuation power flow (CPF) solver.
%   [INPUT PARAMETERS]
%   loadvarloc: load variation location(in external bus numbering). Single
%               bus supported so far.
%   sigmaForLambda: stepsize for lambda
%   sigmaForVoltage: stepsize for voltage
%   [OUTPUT PARAMETERS]
%   max_lambda: the lambda in p.u. w.r.t. baseMVA at (or near) the nose
%               point of PV curve
%   NOTE: the first column in return parameters 'predicted_list,
%   corrected_list, combined_list' is bus number; the last row is lambda.
%   created by Rui Bo on 2007/11/12

%   MATPOWER
%   $Id: cpf.m,v 1.7 2010/04/26 19:45:26 ray Exp $
%   by Rui Bo
%   and Ray Zimmerman, PSERC Cornell
%   Copyright (c) 1996-2010 by Power System Engineering Research Center (PSERC)
%   Copyright (c) 2009-2010 by Rui Bo
%
%   This file is part of MATPOWER.
%   See http://www.pserc.cornell.edu/matpower/ for more info.
%
%   MATPOWER is free software: you can redistribute it and/or modify
%   it under the terms of the GNU General Public License as published
%   by the Free Software Foundation, either version 3 of the License,
%   or (at your option) any later version.
%
%   MATPOWER is distributed in the hope that it will be useful,
%   but WITHOUT ANY WARRANTY; without even the implied warranty of
%   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
%   GNU General Public License for more details.
%
%   You should have received a copy of the GNU General Public License
%   along with MATPOWER. If not, see <http://www.gnu.org/licenses/>.
%
%   Additional permission under GNU GPL version 3 section 7
%
%   If you modify MATPOWER, or any covered work, to interface with
%   other modules (such as MATLAB code and MEX-files) available in a
%   MATLAB(R) or comparable environment containing parts covered
%   under other licensing terms, the licensors of MATPOWER grant
%   you additional permission to convey the resulting work.

%% define named indices into bus, gen, branch matrices

%escalate 'singular' to a matrix so we can use error handling to deal with
%it

% [PQ, PV, REF, NONE, BUS_I, BUS_TYPE, PD, QD, GS, BS, BUS_AREA, VM, ...
%     VA, BASE_KV, ZONE, VMAX, VMIN, LAM_P, LAM_Q, MU_VMAX, MU_VMIN] = idx_bus();
% 
% [F_BUS, T_BUS, BR_R, BR_X, BR_B, RATE_A, RATE_B, ...
%     RATE_C, TAP, SHIFT, BR_STATUS, PF, QF, PT, QT, MU_SF, MU_ST] = idx_brch();
% [GEN_BUS, PG, QG, QMAX, QMIN, VG, MBASE, ...
%     GEN_STATUS, PMAX, PMIN, MU_PMAX, MU_PMIN, MU_QMAX, MU_QMIN] = idx_gen();

if nargin == 0 % run test suite
%     which('cpf.m')
    [path, name, ext] = fileparts(which(sprintf('%s.m',mfilename)));
    runFile = fullfile(path, 'test', sprintf('test_%s.m', name));
    
    fprintf('Running unit-test for <%s%s>  \n=============================\n\n',name,ext);
    run(runFile)
%     pwd
    
%     fullfile(path , 'test', 'test_cpf.m')
%     run(fullfile('test', 'test_cpf.m'));
    
    return;
end




finished = false;

BUS_I = 1;
PD = 3;
QD = 4;
VD = 8;
VA = 9;

GEN_BUS = 1;
VG = 6;
GEN_STATUS = 8;

GLOBAL_CONTBUS = 0; %for use by 'plotBusCurve'

lastwarn('No Warning');
%% assign default parameters
if nargin < 3
    sigmaForLambda = 0.1;       % stepsize for lambda
    sigmaForVoltage = 0.025;    % stepsize for voltage
end

if nargin < 5, verbose = 0; end
if nargin < 6, shouldIPlotEverything = false; else shouldIPlotEverything = plotting; end
if nargin < 7, do_phase3 = true; end

boolStr = {'no', 'yes'};
if verbose, fprintf('CPF\n'); figure; end


if verbose, fprintf('\t[Info]:\tDo Phase 3?: %s\n', boolStr{do_phase3+1}); end

mError = MException('CPF:cpf', 'cpf_error');
%% options
max_iter = 1000;                 % depends on selection of stepsizes

%% ...we use PV curve slopes as the criteria for switching modes
slopeThresh_Phase1 = 0.5;       % PV curve slope shreshold for voltage prediction-correction (with lambda increasing)
slopeThresh_Phase2 = 0.3;       % PV curve slope shreshold for lambda prediction-correction

slopeThresh_Phase2 = 0.7;


%% load the case & convert to internal bus numbering
[baseMVA, busE, genE, branchE] = loadcase(casedata);
[numBuses, ~] = size(busE);



if nargin < 2 %no participation factors so keep the current load profile
	participation = busE(:,PD)./sum(busE(:,PD));
else
	
	participation = participation(:);%(:) forces column vector

	if length(participation) ~= numBuses, %improper number of participations given
		if length(participation) == 1 && participation > 0,%assume bus number is specified instead
			participation = (1:numBuses)'==participation;
		else
			if verbose, fprintf('\t[Info]\tParticipation Factors improperly specified.\n\t\t\tKeeping Current Loading Profile.\n'); end
			participation = busE(:,PD)./sum(busE(:,PD));
		end
	end
end

%i2e is simply the bus ids stored in casedata.bus(:,1), so V_corr can be
%outputted as is with rows corresponding to entries in casedata.bus
[i2e, bus, gen, branch] = ext2int(busE, genE, branchE);
e2i = sparse(max(i2e), 1);
e2i(i2e) = (1:size(bus, 1))';
participation_i = participation(e2i(i2e));

participation_i = participation_i ./ sum(participation_i); %normalize










%specify whether or not to use lagrange polynomial interpolation when
%possible; default is true
useLagrange=false;
useAdaptive=false;

strs = {'no', 'yes'};
if verbose, fprintf('\t[Info]:\tLagrange: %s\n', strs{useLagrange+1}); end
if verbose, fprintf('\t[Info]:\tAdaptive Step Size: %s\n', strs{useAdaptive+1}); end











%% get bus index lists of each type of bus
[ref, pv, pq] = bustypes(bus, gen);


%define a default result to return if we fail out before running any
%computations
    defaultResults.max_lambda = sum( bus(:,PD) )/ baseMVA; % set so that power calculation will return sum(bus(:,PD));
    defaultResults.V_corr = [];
    defaultResults.V_pr = [];
    defaultResults.lambda_corr = [];
    defaultResults.lambda_pr =[];
    defaultResults.success=false;
    defaultResults.time = 0;
    
%% GO THROUGH CONDITIONS FOR ABORTING  
if nnz(participation_i) < 2,
    %in this situation voltage won't droop and we get a bad computation.
    %instead returns lambda to give current power as the maximum. This is
    %under-stating the max loadability but hopefully not by too much.
    %Requires a reasonable starting power value
    
    defaultResults.success = true;
    max_lambda = defaultResults;
    return;
end
    
    
if isempty(ref), %if no reference bus is returned, throw an error
   mError = addCause(mError, mException('MATPOWER:bustypes', 'No ref bus returned'));
   throw(mError);
end

if isempty(pq) && isempty(pv),
   mError = addCause(mError, mException('MATPOWER:bustypes', 'NO PV or PQ buses returned; network is trivial'));
   throw(mError);
end
if isempty(pq), %if there is no PQ bus, all voltages are set by generators and we cannot run CPF.
    defaultResults.success = true;
    max_lambda = defaultResults;
    return;
else
    continuationBus = pq(1);
end

if any(isnan(participation_i)), %could happen if no busses had loads
	participation_i = zeros(length(participation_i), 1);
	participation_i(pq) = 1/numel(participation_i(pq));
end

%% generator info
on = find(gen(:, GEN_STATUS) > 0);      %% which generators are on?
gbus = gen(on, GEN_BUS);                %% what buses are they at?

%% form Ybus matrix

[Ybus, ~, ~] = makeYbus(baseMVA, bus, branch);
if det(Ybus) == 0
    mError = addCause(mError, MException('MATPOWER:makeYBus', 'Ybus is singular'));
end

%% initialize parameters
% set lambda to be increasing
flag_lambdaIncrease = true;  % flag indicating lambda is increasing or decreasing

%get all QP ratios
initQPratio = bus(:,QD)./bus(:,PD);
if any(isnan(initQPratio)), 
	if verbose > 1, fprintf('\t[Warning]:\tLoad real power at bus %d is 0. Q/P ratio will be fixed at 0.\n', find(isnan(initQPratio)));  end
	initQPratio(isnan(initQPratio)) = 0;
end













%%------------------------------------------------
% do cpf prediction-correction iterations
%%------------------------------------------------
t0 = clock;

nPoints = 0;
% V_pr=[];
% lambda_pr = [];
% V_corr = [];
% lambda_corr = [];

V_pr = zeros(size(bus,1), 400);
V_corr = zeros(size(bus,1),400);
lambda_pr = zeros(1,400);
lambda_corr = zeros(1,400);
nSteps = zeros(1,400);
stepSizes = zeros(1,400);





%% do voltage correction (ie, power flow) to get initial voltage profile
if ~finished,
    
    % first try solving for a flat start: 0 power, all voltages 1 p.u.
    lambda0 = 0;
    lambda = lambda0;
    Vm = ones(size(bus, 1), 1);          %% flat start
    Va = bus(ref(1), VA) * Vm;
    V  = Vm .* exp(1i* pi/180 * Va);
    V(gbus) = gen(on, VG) ./ abs(V(gbus)).* V(gbus);
    
    
    lambda_predicted = lambda;
    V_predicted = V;
    [V, lambda, success, iters] = cpf_correctVoltage(baseMVA, bus, gen, Ybus, V_predicted, lambda_predicted, initQPratio, participation_i);
    
    
    
    
    if ~success, 
       % If flat start fails, try with voltages, angles and powers from
       % input case
        Vm = bus(:,VD); %get bus voltages from case
        Va = bus(:,VA); %get bus angles from case
        V  = Vm .* exp(1i* pi/180 * Va);
        V(gbus) = gen(on, VG) ./ abs(V(gbus)).* V(gbus);
        
        lambda = sum(bus(:,PD)) / baseMVA; %get lambda value that will give bus(:,PD) in cpf_correctVoltage(..) below
        lambda_predicted = lambda;
        [V, lambda, success, iters] = cpf_correctVoltage(baseMVA, bus, gen, Ybus, V_predicted, lambda_predicted, initQPratio, participation_i);
    end
    
    
    if success == false,
        mError = addCause(mError, MException('CPF:correctVoltageError', 'Could not solve for initial point'));
        throw(mError);
    end

    if any(isnan(V))
        mError = addCause(mError,MException('CPF:correctVoltageError', 'Generating initial voltage profile'));
        mError = addCause(mError,MException('CPF:correctVoltageError', ['NaN bus voltage at ', mat2str(i2e(isnan(V)))]));    
        throw(mError);
    end

    stepSize = 1;
    logStepResults();
    nPoints = nPoints + 1;
end









%% --- Start Phase 1: voltage prediction-correction (lambda increasing)
if verbose > 0, fprintf('Start Phase 1: voltage prediction-correction (lambda increasing).\n'); end

lagrange_order = 6;

%parametrize step size for Phase 1
minStepSize = 0.01;
maxStepSize = 200;

stepSize = sigmaForLambda;
% stepSize = 10;

if useAdaptive,
    stepSize = min(max(stepSize, minStepSize),maxStepSize);
end


function y= mean_log(x)
    y = log(x./mean(x));
end

function out = check_stepSizes(thresh)
    if nargin < 1, thresh = 2;  end
%     vals = [stepSizes(max(1,nPoints-lagrange_order+1):nPoints), stepSize]
%     a = mean_log([stepSizes(max(1,nPoints-lagrange_order+1):nPoints), stepSize])
%     b = log(abs(diff([stepSizes(max(1,nPoints-lagrange_order+1):nPoints), stepSize])))
%     c = mean_log(abs(diff([stepSizes(max(1,nPoints-lagrange_order+1):nPoints), stepSize])))
%     out = any( abs(mean_log([stepSizes(max(1,nPoints-lagrange_order+1):nPoints), stepSize])) > thresh);
    out = any( mean_log(abs(diff([stepSizes(max(1,nPoints-lagrange_order+1):nPoints), stepSize]))) > thresh);


end



i = 0; j=0; k=0; %initialize counters for each phase to zero
phase1 = true; phase2 = false; phase3 = false;
while i < max_iter && ~finished    
    i = i + 1; % update iteration counter
    
    % save good data
    V_saved = V;
    lambda_saved = lambda;
    
	if  ~useLagrange ||  (nPoints<2 || check_stepSizes() || slope * (-1)^~flag_lambdaIncrease < 1e-10), % do voltage prediction to find predicted point (predicting voltage)
        %fallback to first-order approximation
		[V_predicted, lambda_predicted, ~] = cpf_predict(Ybus, ref, pv, pq, V, lambda, stepSize, 1, initQPratio, participation_i, flag_lambdaIncrease);
    else %if we have enough points, use lagrange polynomial
		[V_predicted, lambda_predicted] = cpf_predict_voltage(V_corr(:,1:nPoints), lambda_corr(1:nPoints), lambda, stepSize, ref, pv, pq, flag_lambdaIncrease, lagrange_order);
    end
    
           
    %% check prediction to make sure step is not too big so as to cause non-convergence    
    error_predicted = max(abs(V_predicted- V));
    if useAdaptive && error_predicted > maxStepSize && ~success %-> this is inappropriate since 'success' would be coming from previous correction step
        newStepSize = 0.8*stepSize; %cut down the step size to reduce the prediction error
        if newStepSize > minStepSize,
            if verbose, fprintf('\t\tPrediction step too large (voltage change of %.4f). Step Size reduced from %.5f to %.5f\n', error_predicted, stepSize, newStepSize); end
            stepSize = newStepSize;
            i = i-1;            
            continue;
        end       
    end
    
    %% do voltage correction to find corrected point
    [V, lambda, success, iters] = cpf_correctVoltage(baseMVA, bus, gen, Ybus, V_predicted, lambda_predicted, initQPratio, participation_i);
	
    
%     
%     if i >= 2,
%         demonstratePrediction();
%         fprintf('wait');
%     end
    
    % if voltage correction fails, reduce step size and try again
    if useAdaptive && success == false  && stepSize > minStepSize,
        newStepSize = stepSize * 0.3;
        if newStepSize > minStepSize,	
            if verbose, fprintf('\t\tCorrection step didnt converge; changed stepsize from %.5f to: %.5f\n', stepSize, newStepSize); end
            stepSize = newStepSize;
            i = i-1;
            V = V_saved;
            lambda = lambda_saved;
            continue;
        end
    end

    
    
    %% calculate slope (dP/dLambda) at current point
	[slope, ~] = max(abs(V-V_saved)  ./ (lambda-lambda_saved)); %calculate maximum slope at current point.
	
    
  

    
    %% if successful, check max error and adjust step sized to get a better error (meaning, balanced between a bigger step size and making sure we still converge)
	error = abs(V-V_predicted)./abs(V);
%     error_order = log(mean(error)/ 0.0001);
    error_order = log(mean(error)/ 0.0005);

%     error_order = log(mean(error)/ 0.001);
%     error_order = log(mean(error)/ 0.01);

    
	if useAdaptive && abs(error_order) > 0.5 && mean(error)>0, % adjust step size to improve error outcome
%         newStepSize = stepSize - 0.1*error_order); %adjust step size
        newStepSize = stepSize - 0.07*error_order; %adjust step size
        newStepSize = max( min(newStepSize,maxStepSize),minStepSize); %clamp step size
        
		if verbose, fprintf('\t\tmean prediction error: %.15f. changed stepsize from %.2f to %.2f\n', mean(error), stepSize, newStepSize); end
        stepSize = newStepSize;
    end
    
    
    if useAdaptive && success && nPoints < 2 && slope > slopeThresh_Phase1, %dampen step size in cases where slope is reduced too quickly.
       newStepSize = stepSize * 0.01;
       if newStepSize > 0.000001,
            if verbose, fprintf('\t\tArrived at Phase 2 too quickly; changed stepsize from %.5f to: %.5f\n', stepSize, newStepSize); end
            stepSize = newStepSize;
       end
    end
    
    if useAdaptive && mean(error) < 1e-15,
        newStepSize = stepSize* 1.2;
        
        newStepSize = max( min(newStepSize,maxStepSize),minStepSize); %clamp step size
        if verbose, fprintf('\t\tmean prediction error: %.15f. changed stepsize from %.2f to %.2f\n', mean(error), stepSize, newStepSize); end
        stepSize = newStepSize;
    end
    
	

    
    if success % if correction converged we can save the point and do plotting/output in verbose mode
        logStepResults();        
		if verbose && shouldIPlotEverything, plotBusCurve(continuationBus, nPoints+1); end
        nPoints = nPoints + 1;
    end
    
    
    	
    % instead of using condition number as criteria for switching between
    % modes...
    %    if rcond(J) <= condNumThresh_Phase1 | success == false % Jacobian matrix is ill-conditioned, or correction step fails
    % ...we use PV curve slopes as the criteria for switching modes:    
    if abs(slope) >= slopeThresh_Phase1 || success == false % Approaching nose area of PV curve, or correction step fails
        
        % restore good data point if convergence failed
        if success == false
            V = V_saved;
            lambda = lambda_saved;
            i = i-1;
        end 

		if verbose > 0
			if ~success, 
				if ~isempty(strfind(lastwarn, 'singular')), 
					fprintf('\t[Info]:\tMatrix is singular. Aborting Correction.\n'); 
					lastwarn('No error');
					break;
				else
					fprintf('\t[Info]:\tLambda correction fails.\n'); 
				end
			else
				fprintf('\t[Info]:\tApproaching nose area of PV curve.\n');
			end
		end
        break;    
    end
end
phase1 = false;

% fprintf('Average prediction error for voltage: %f\n', mean(mean( abs( V_corr - Vpr)./abs(V_corr))));
% fprintf('Avg num of iterations: %f\n', mean(correctionIters));
if verbose > 0
    fprintf('\t[Info]:\t%d data points contained in phase 1.\n', i);
end


if i < 1,
    mError = addCause(mError, MException('CPF:Phase1', 'no points in phase 1'));
end






%% --- Switch to Phase 2: lambda prediction-correction (voltage decreasing)
if verbose > 0
    fprintf('Switch to Phase 2: lambda prediction-correction (voltage decreasing).\n');
end

p2_avoidLagrange = false;

maxStepSize = 0.04;
minStepSize = 0.0000001;

continuationBus = pickBus(useLagrange);


if useAdaptive,
    try %try to previous voltage step on continuation bus to start with.
        if stepSize < maxStepSize, %check that step size hasn't been reduced already
            stepSize = stepSize;
        else
            stepSize = abs(V(continuationBus) - V_saved(continuationBus));
        end
        
        
    catch %if this fails (e.g. V_saved was never defined) revert to preset value
        stepSize = sigmaForVoltage;
    end
    stepSize = min(max(stepSize, minStepSize),maxStepSize);
else
    stepSize = sigmaForVoltage;
end
    
j = 0;

 
phase2 = true;
while j < max_iter && ~finished
    %% update iteration counter
    j = j + 1;

    % save good data
    V_saved = V;
    lambda_saved = lambda;
    
    
    %% do lambda prediction to find predicted point (predicting lambda)
	if ~useLagrange  || (~useAdaptive && j <= lagrange_order) || p2_avoidLagrange || (nPoints<4 || check_stepSizes() || slope * (-1)^~flag_lambdaIncrease < 1e-10),
        [V_predicted, lambda_predicted, J] = cpf_predict(Ybus, ref, pv, pq, V, lambda, stepSize, [2, continuationBus], initQPratio, participation_i,flag_lambdaIncrease);
%         usedLagrange = false;
    else
        [V_predicted, lambda_predicted] = cpf_predict_lambda(V_corr(:,1:nPoints), lambda_corr(1:nPoints), lambda_saved, stepSize, continuationBus, ref, pv, pq, lagrange_order);
%         usedLagrange = true;
    end
    
    if verbose && shouldIPlotEverything,
        hold on; plot(lambda_predicted, abs(V_predicted(continuationBus)), 'go'); hold off;
    end
    
    if (useLagrange && ~p2_avoidLagrange) && any(isnan(V_predicted))
       p2_avoidLagrange = true;
       if verbose, fprintf('\t\tAbandoning lagrange\n'); end
       j = j-1; continue;
    end
    
	if useAdaptive && abs(lambda_predicted - lambda) > maxStepSize || lambda_predicted < 0,
        newStepSize = stepSize * 0.8;
        
        if abs(lambda_predicted - lambda) > 10*maxStepSize,
            p2_avoidLagrange = true;
        end
        
        if newStepSize > minStepSize,
            if verbose, fprintf('\t\tPrediction step too large (lambda change of %.4f). Step Size reduced from %.7f to %.7f\n', abs(lambda_predicted - lambda), stepSize, newStepSize); end
            stepSize = newStepSize;
            j = j-1;
            continue;
        end
	end
    
    %% do lambda correction to find corrected point
    Vm_assigned = abs(V_predicted);
    
  
	
	[V, lambda, success, iters] = cpf_correctLambda(baseMVA, bus, gen, Ybus, Vm_assigned, V_predicted, lambda_predicted, initQPratio, participation_i, ref, pv, pq, continuationBus);
 	
    if verbose && shouldIPlotEverything
        hold on; plot(lambda, abs(V(continuationBus)), 'b.'); hold off;
    end
    
    
    if ~success,
        fprintf('fail');
    end
%     if nPoints > 2,
%        demonstratePrediction(max(1,nPoints-10), nPoints); 
%        fprintf('wait');
%     end
    
    
    if useAdaptive && abs(lambda - lambda_saved) > maxStepSize %|| ~success, 
        if abs(lambda - lambda_saved) > maxStepSize * 10,
            p2_avoidLagrange = true;
        end
        
        % ...otherwise, reduce the step size, discard and try again
        newStepSize = stepSize * 0.2;
        if newStepSize > minStepSize,
            if verbose, fprintf('\t\tcontinuationBus = %d', continuationBus); end
            if verbose, fprintf('\t\tLambda step too big; lambda step = %3f). Step size reduced from %.7f to %.7f\n', lambda-lambda_saved, stepSize, newStepSize); end            
             
            stepSize = newStepSize;
            V = V_saved;
            lambda = lambda_saved;
            j = j-1;
            continue;
        end
         
    end
    
    
    
    
    
    %Here we check the change in Voltage if correction did not converge; if
    %the step is larger than the minimum then we can reduce the step size,
    %discard the sample and try again.
    mean_step = mean( abs(V_predicted-V_saved));    
	prediction_error = mean(abs(V-V_predicted)./abs(V));
    
%     error_order = log(prediction_error/0.000001);
    error_order = log(prediction_error/0.000005);
%     error_order = log(prediction_error/0.00001);   
    
    if useAdaptive && ( (mean_step > 0.00001 || stepSize > 0) && ~success) % if we jumped too far and correction step didn't converge
        newStepSize = stepSize * 0.4;
        if newStepSize >= minStepSize, %if we are not below min step-size threshold go back and try again with new stepSize
            if verbose, fprintf('\t\tDid not converge; voltage step: %f pu. Step Size reduced from %.7f to %.7f\n', mean_step, stepSize, newStepSize); end
            stepSize = newStepSize;
            V = V_saved;
            lambda= lambda_saved;
            j =  j-1;
            continue;
        end
    end
    
    
    
    if useAdaptive && abs(error_order) > 0.75 && prediction_error>0,
%     if abs(error_order) > 1.5 && prediction_error>0, 
        %if we havent just dropped the stepSize, consider changing it to
        %get a better error outcome. this allows us to increase our steps
        %to go faster or reduce our steps to avoid non-convergence, which
        %is time consuming.
        newStepSize = stepSize * (1 + 0.15*(error_order < 1) - 0.15*(error_order>1));
        newStepSize = max( min(newStepSize,maxStepSize),minStepSize); %clamp step size
        
		if verbose && newStepSize ~= stepSize, fprintf('\t\tAdjusting step size from %.7f to %.7f; mean prediction error: %.15f.\n', stepSize, newStepSize, prediction_error); end

        stepSize = newStepSize;
    end
	
    
	
    continuationBus = pickBus(useLagrange);

    
    if success %if correction step converged, log values and do verbosity
		logStepResults();        
		if verbose && shouldIPlotEverything, plotBusCurve(continuationBus, nPoints+1); end
        nPoints = nPoints + 1;
    end
    
    
    
    % instead of using condition number as criteria for switching between
    % modes...
    %    if rcond(J) >= condNumThresh_Phase2 | success == false % Jacobian matrix is good-conditioned, or correction step fails
    % ...we use PV curve slopes as the criteria for switching modes:
    if ~success || (slope < 0 && slope > -slopeThresh_Phase2),
        if ~success,
            % restore good data
            V = V_saved;
            lambda = lambda_saved;
            j = j-1;
        end
        
        %% ---change to voltage prediction-correction (lambda decreasing)
        if verbose > 0
			if ~success, 
				if ~isempty(strfind(lastwarn, 'singular'))
					fprintf('\t[Info]:\tMatrix is singular. Aborting Correction.\n');
					lastwarn('No error'); break;
				else
					fprintf('\t[Info]:\tLambda correction fails.\n');
				end
			else
				fprintf('\t[Info]:\tLeaving nose area of PV curve.\n');
			end
        end
        break;   
    end
    
%     if verbose, fprintf('lambda: %.3f,     slope: %.4f     error: %e    error_order: %f     stepSize: %.15f\n', lambda, slope, prediction_error, error_order,stepSize); end
end
phase2 = false;

if ~success && lambda_corr(nPoints) > lambda_corr(nPoints-1),
    %failed out before reaching the nose    
    if verbose, fprintf('\t\t[Info]:\tFailed out of Phase 2 before reaching PV nose. Aborting...\n'); end
    mError = MException('CPF:convergeError', 'Phase 2 voltage correction failed before reaching nose.');
    throw(mError);
end



% fprintf('Average prediction error for voltage: %f\n', mean(predictionErrors2));
% fprintf('Avg num of iterations: %f\n', mean(correctionIters2));
if verbose > 0
    fprintf('\t[Info]:\t%d data points contained in phase 2.\n', j);
end


    function cntBus = pickBus(avoidPV)
        % Describes the process for picking a continuation Bus for the next
        % iteration       
        if nargin < 1, avoidPV = true; end

      %how to pick the continuation bus during Phase 2:
        % 1. calculate slope (dP/dLambda) at current point
        mSlopes = abs(V-V_saved)./(lambda-lambda_saved);

        % 2. check if we have passed the peak of the PV curve
        if flag_lambdaIncrease && any(mSlopes < 0), flag_lambdaIncrease = false; end

        % 3. choose the buses that could be continuation buses.
        if avoidPV, mBuses  = pq;
        else mBuses = [pv; pq]; 
        end
        
        %try to eliminate buses with 0 real slope
        newMBuses = setdiff( mBuses, find( (abs(V)-abs(V_saved)) == 0));
        if ~isempty(newMBuses), mBuses = newMBuses; end

        [~, ind] = max(mSlopes(mBuses) .* (-1)^~flag_lambdaIncrease);
        cntBus = mBuses(ind);
        slope = mSlopes(cntBus);     
    end

























%% --- Switch to Phase 3: voltage prediction-correction (lambda decreasing)
if verbose > 0
    fprintf('Switch to Phase 3: voltage prediction-correction (lambda decreasing).\n');
end
% set lambda to be decreasing
flag_lambdaIncrease = false; 


%set step size for Phase 3

if useAdaptive,
    minStepSize = 0.2*stepSize;
    maxStepSize = 2;
    try
        stepSize = lambda_saved - lambda;
    catch
       stepSize = stepSize; 
    end

    stepSize = min(max(stepSize, minStepSize),maxStepSize);

else
    stepSize = sigmaForLambda;
end

if ~do_phase3, finished = true; end

k = 0;
phase3 = true;
while k < max_iter && ~finished
    %% update iteration counter
    k = k + 1;
    
    
    %% store V and lambda
    V_saved = V;
    lambda_saved = lambda;
    
    if  ~useLagrange || (~useAdaptive && k < lagrange_order) || (nPoints<4 || check_stepSizes() || slope * (-1)^~flag_lambdaIncrease < 1e-10), % do voltage prediction to find predicted point (predicting voltage)
		[V_predicted, lambda_predicted, ~] = cpf_predict(Ybus, ref, pv, pq, V, lambda, stepSize, 1, initQPratio, participation_i, flag_lambdaIncrease);
    else %if we have enough points, use lagrange polynomial
		[V_predicted, lambda_predicted] = cpf_predict_voltage(V_corr(:,1:nPoints), lambda_corr(1:nPoints), lambda, stepSize, ref, pv, pq, flag_lambdaIncrease, lagrange_order);
    end
    
%     %% do voltage prediction to find predicted point (predicting voltage)
%     [V_predicted, lambda_predicted, ~] = cpf_predict(Ybus, ref, pv, pq, V, lambda, stepSize, 1, initQPratio, participation_i, flag_lambdaIncrease);

    %% do voltage correction to find corrected point
    [V, lambda, success, iters] = cpf_correctVoltage(baseMVA, bus, gen, Ybus, V_predicted, lambda_predicted, initQPratio, participation_i);
	
%     if nPoints > 2,
%         demonstratePrediction(max(1,nPoints-10), nPoints);   
%         fprintf('wait');
%     end
    mean_step = mean( abs(V-V_saved));        
    if useAdaptive && ( mean_step > 0.0001 && ~success) % if we jumped too far and correction step didn't converge
        newStepSize = stepSize * 0.4;
        if newStepSize > minStepSize, %if we are not below min step-size threshold go back and try again with new stepSize
            if verbose, fprintf('\t\tDid not converge; voltage step: %f pu. Step Size reduced from %.5f to %.5f\n', mean_step, stepSize, newStepSize); end
            stepSize = newStepSize;
            V = V_saved;
            lambda= lambda_saved;
            k =  k-1;
            continue;
        end
    end
    prediction_error = mean( abs( V-V_predicted));
    error_order = log(prediction_error/0.001);
%     error_order = log(mean(error)/ 0.005);

    
    if useAdaptive && abs(error_order) > 0.8 && prediction_error>0,
%         newStepSize = stepSize - 0.03*error_order; %adjust step size
        newStepSize = stepSize - 0.03*error_order; %adjust step size

%         newStepSize = stepSize * (1 + 0.8*(error_order < 1) - 0.8*(error_order>1));
        newStepSize = max( min(newStepSize,maxStepSize),minStepSize); %clamp step size
        
   		if verbose && newStepSize ~= stepSize, fprintf('\t\tAdjusting step size from %.6f to %.6f; mean prediction error: %.15f.\n', stepSize, newStepSize, prediction_error); end
        
% 		if verbose, fprintf('\t\tmean prediction error: %.15f. changed stepsize from %.5f to %.5f\n', mean_error, stepSize, newStepSize); end
        stepSize = newStepSize;
    elseif useAdaptive && mean_step > 0 && prediction_error == 0,
       %we took a step but prediction was dead on
        newStepSize = stepSize * 2;
        newStepSize = max( min(newStepSize,maxStepSize),minStepSize); %clamp step size
        if verbose && newStepSize ~= stepSize, fprintf('\t\tAdjusting step size from %.6f to %.6f; mean prediction error: %.15f.\n', stepSize, newStepSize, prediction_error); end

        stepSize = newStepSize;

    end
   
    if lambda < 0 % lambda is less than 0, then stop CPF simulation
        if verbose > 0, fprintf('\t[Info]:\tlambda is less than 0.\n\t\t\tCPF finished.\n'); end
        k = k-1;
        break;
    end
    
    
    if success,
        logStepResults()        
		if verbose && shouldIPlotEverything, plotBusCurve(continuationBus, nPoints+1); end
        nPoints = nPoints + 1;        
    end
    
    
    if ~success % voltage correction step fails.
		V = V_saved;
        lambda = lambda_saved;
        k = k-1;
        if verbose > 0
			if ~isempty(strfind(lastwarn, 'singular'))
				fprintf('\t[Info]:\tMatrix is singular. Aborting Correction.\n');
				lastwarn('No error');
				break;
			else
				fprintf('\t[Info]:\tVoltage correction step fails..\n');
			end
        end
        break;        
    end
end
phase3=false;
if verbose > 0, fprintf('\t[Info]:\t%d data points contained in phase 3.\n', k); end





%% Get the last point (Lambda == 0)
if success && do_phase3, %assuming we didn't fail out, try to solve for lambda = 0
    [V_predicted, lambda_predicted, ~] = cpf_predict(Ybus, ref, pv, pq, V, lambda_saved, lambda_saved, 1, initQPratio, participation_i, flag_lambdaIncrease);
    [V, lambda, success, iters] = cpf_correctVoltage(baseMVA, bus, gen, Ybus, V_predicted, lambda_predicted, initQPratio, participation_i);
    
    if success,        
		logStepResults()
        if shouldIPlotEverything, plotBusCurve(continuationBus, nPoints+1); end
        
        nPoints = nPoints + 1;
    end
end

if verbose > 0, fprintf('\n\t[Info]:\t%d data points total.\n', nPoints); end

V_corr = V_corr(:,1:nPoints);
lambda_corr = lambda_corr(1:nPoints);
V_pr = V_pr(:,1:nPoints);
lambda_pr = lambda_pr(1:nPoints);
nSteps = nSteps(1:nPoints);
stepSizes = stepSizes(1:nPoints);
max_lambda = max(lambda_corr);

if lambda <= max_lambda,
    success = true;
end



if shouldIPlotEverything, 
    plotBusCurve(continuationBus);
%     myaa();
    figure;	
    
    hold on;      
        plot(lambda_corr, abs(V_corr(pq,:))); 
        maxL =plot([max_lambda, max_lambda], ylim,'LineStyle', '--','Color',[0.8,0.8,0.8]);  
%         mText = text(max_lambda*0.85, 0.1, sprintf('Lambda: %3.2f',max_lambda), 'Color', [0.7,0.7,0.7]);
        
        ticks = get(gca, 'XTick');
        ticks = ticks(abs(ticks - ml) > 0.5);
        ticks = sort(unique([ticks round(ml*1000)/1000]));
        set(gca, 'XTick', ticks);
    
        uistack(maxL, 'bottom');    
%         uistack(mText, 'bottom');
    hold off;
    
    
    title('Power-Voltage curves for all PQ buses.');
    ylabel('Voltage (p.u.)')
    xlabel('Power (lambda load scaling factor)');
    
%     ylims = ylim;
    
    figure;
    %%
    plot([lambda_corr(1), lambda_corr(1) + cumsum(abs(diff(lambda_corr)))],real(V_corr(continuationBus,:)), 'o')
    hold on;
    
    xpos = lambda_corr(1) + cumsum(abs(diff(lambda_corr)));
    slopes = real(diff(V_corr(continuationBus,:))) ./ diff(lambda_corr);
    plot(xpos, slopes, 'r')
    hold off;
    
end
et = etime(clock, t0);

if verbose > 0, 
    fprintf('\t[Info]:\tMax Lambda Value: %.4f\n', max_lambda);
    fprintf('\t[Info]:\tAverage step size: %.6f\n', mean(stepSizes));
    fprintf('\t[Info]:\tAverage # iterations: %.2f\n', mean(nSteps)); 
    fprintf('\t[Info]:\tCompletion time: %.3f seconds.\n', et); 
end
%% reorder according to exterior bus numbering

if nargout > 1, % LEGACY create predicted, corrected, combined lists
%     combined_list = zeros( size(V_corr,1) + 1, 1+size(V_corr,2) + size(Vpr,2)-1);
    predicted_list = [ [bus(:,1); 0] [V_pr; lambda_pr]];
    corrected_list = [ [bus(:,1); 0] [V_corr; lambda_corr]];
    
    combined_list = [bus(:,1); 0];
    combined_list(:,(1:size(V_corr,2))*2) = [V_corr; lambda_corr];
    combined_list(:,(1:size(V_pr,2)-1)*2+1) = [V_pr(:,2:end); lambda_pr(2:end)];
    
end


if nargout == 1,
	results.max_lambda = max_lambda;
	results.V_pr = V_pr;
	results.lambda_pr = lambda_pr;
	results.V_corr = V_corr;
	results.lambda_corr = lambda_corr;
	results.success = success;
	results.time = et;
	
	max_lambda = results; %return a single struct
end
    
    function logStepResults()
        % quicky for logging the results of an iteration, which happens the
        % same in each phase.
        
        V_pr(:,nPoints+1) = V_predicted;
        lambda_pr(nPoints+1) = lambda_predicted;
        V_corr(:,nPoints+1) = V;
        lambda_corr(:,nPoints+1) = lambda;
        nSteps(:,nPoints+1) = iters;
        stepSizes(:,nPoints+1) = stepSize;
    end
    
    function plotBusCurve(bus, mIndex)
        % This function creates a pretty plot of prediction/correction up
        % to the current point, for the bus specified, including colour
        % coding of phases in CPF
        
        if nargin<2,
            mIndex = nPoints;
        end
        
        
        if bus == GLOBAL_CONTBUS, %if its the same bus as last time, check resizing of window.
            xlims = xlim;
            ylims = ylim;

            xlims(1) = min(xlims(1),  lambda_corr(mIndex) - (xlims(2) - lambda_corr(mIndex)) * 0.1);
            xlims(2) = max(xlims(2),  lambda_corr(mIndex) + (lambda_corr(mIndex) - xlims(1)) * 0.1);
%             xlims(2) = max(xlims(1) + (lambda_corr(nPoints)- xlims(1)) * 1.2, xlims(2));
%             ylims(1) = min(ylims(2) - (ylims(2) - abs(V_corr(bus,nPoints)))*1.2, ylims(1));
            ylims(1) = min(ylims(1), abs(V_corr(bus,mIndex)) - (ylims(2) - abs(V_corr(bus,mIndex)))*0.1);
            ylims(2) = max(ylims(2), abs(V_corr(bus,mIndex)) + (abs(V_corr(bus,mIndex)) - ylims(1))*0.1);
        end
        
        markerSize = 8;
        
        
        pred = plot(lambda_pr(1:1+i+j+k), abs(V_pr(bus,1:1+i+j+k)),'o', 'Color', [0.9137,0.4275,0.5451], 'LineWidth', 2); hold on;
        
        
        %plot phase 3
        p3=plot(lambda_corr(1+i+j:1+i+j+k), abs(V_corr(bus, 1+i+j:1+i+j+k)), '.-b', 'markers',markerSize, 'Color', [  0.2510    0.5412    0.8235]); hold on;
        
        %plot phase 2
        p2=plot(lambda_corr(1+i:1+i+j), abs(V_corr(bus, 1+i:1+i+j)), '.-g', 'markers', markerSize, 'Color', [0.3490    0.7765    0.4078]);
        
        %plot phase 1
        p1=plot(lambda_corr(1:1+i), abs(V_corr(bus,1:i+1)), '.-b', 'markers', markerSize, 'Color', [  0.2510    0.5412    0.8235]);
        
        
        %plot initial point
        st=plot(lambda_corr(1), abs(V_corr(bus,1)), '.-k', 'markers', markerSize);
             
        if 1+i+j+k < nPoints,             
            plot( lambda_pr(nPoints), abs(V_pr(bus,nPoints)),'o', 'Color', [0.9137,0.4275,0.5451],'LineWidth', 2)
            en=plot(lambda_corr(end-1:end), abs(V_corr(bus, end-1:end)),'.-k', 'markers', markerSize);                       
        end
%         fprintf('Points in 1, Phase 1, Phase 2, Phase 3: %d. Total Points: %d',1+i+j+k, pointCnt)
        
%         pred=scatter(lambda_pr(1:1+i+j+k), abs(V_pr(bus,1:1+i+j+k)),'r'); hold off;
        
        
%         title(sprintf('Power-Voltage curve for bus %d.', continuationBus));
        ylabel('Voltage (p.u.)')
        xlabel('Power (lambda load scaling factor)');
        ml = max(lambda_corr);
        
        ticks = get(gca, 'XTick');
        ticks = ticks(abs(ticks - ml) > 0.25);
        ticks = sort(unique([ticks round(ml*1000)/1000]));
        set(gca, 'XTick', ticks);
        hold on;
            mLine=plot( [ml, ml], ylim, 'LineStyle', '--', 'Color', [0.8,0.8,0.8]);
            uistack(mLine, 'bottom');
        hold off;
        legend([pred, p1,p2, mLine], {'Predicted Values', 'Lambda Continuation', 'Voltage Continuation', 'Max Lambda'})
        
        if bus == GLOBAL_CONTBUS,
            xlim(xlims);
            ylim(ylims);
            
        end
        
        GLOBAL_CONTBUS = bus;
        a = 1;
        
        set(gca, 'xcolor', [0 0 0],...
         'ycolor', [0 0 0],...
         'color', 'none');
     

        set(gcf, 'color', 'none',...
                 'inverthardcopy', 'off');

    end

    function demonstratePrediction(startPt, endPt)
        % Use this function to demonstrate the difference between lagrange
        % versus linear approximation during the prediction step.
        %
        % This function can be used by calling 'demonstratePrediction()' after
        % i reaches a value high enough to do meaningful lagrange predictions
        % (4 or greater). Call it after finding the correction point as
        % follows:
        %
        % 
        % [V, lambda] = cpf_correct(...);
        %
        % if i >= 4,
        %     demonstratePrediction();
        %     %equivalent to:
        %     % demonstratePrediction(1,i);
        % end
        
        if nargin < 1,
            startPt = 1;
        end
        if nargin < 2, 
        endPt = nPoints;
        end
        
        pts_to_take = startPt:endPt;

        %plot previous points
        prev_pr = scatter(lambda_pr(pts_to_take), abs(V_pr(continuationBus,pts_to_take)), 'r', 'MarkerFaceColor', 'r');
         hold on;prev_corr = plot( lambda_corr(pts_to_take), abs(V_corr(continuationBus,pts_to_take)), 'b.-', 'LineWidth', 1);  hold off;


        %define the range over which to compute predictions
        sigmaRange = max( -1.2*stepSize, -lambda_saved):0.001: 1.2*stepSize;
        sigmaRange = linspace(max( -1.2*stepSize, -lambda_saved), 1.2*stepSize, 4000);


        times = zeros(1, length(sigmaRange));
        
        
        
        
        
        
        %get linear predictions
        V_linear = zeros(1, length(sigmaRange));   l_linear = zeros(1,length(sigmaRange));
        for sample = 1:length(sigmaRange),
            if phase1 || phase3,
                tic;
                [mVs, mL,~] = cpf_predict(Ybus, ref, pv, pq, V_saved, lambda_saved, sigmaRange(sample), 1, initQPratio, participation_i, flag_lambdaIncrease);
                times(sample) = toc;
            elseif phase2,
                tic;
                [mVs, mL, ~] = cpf_predict(Ybus, ref, pv, pq, V_saved, lambda_saved, sigmaRange(sample), [2, continuationBus], initQPratio, participation_i,flag_lambdaIncrease);
                times(sample) = toc;

            end
            V_linear(sample) = abs(mVs(continuationBus)); l_linear(sample) = mL;
        end
        
        fprintf('average of %d iterations of linear predictor: %f seconds\n', length(sigmaRange), mean(times));
        
        
        
        
        
        
        %get lagrange predictions
        V_lagrange = zeros(1, length(sigmaRange));  l_lagrange = zeros(1, length(sigmaRange));

        for sample = 1:length(sigmaRange)
            if phase1 || phase3,
                tic;
                    [mVs, mL] = cpf_predict_voltage(V_corr(:,1:endPt), lambda_corr(1:endPt), lambda_saved, sigmaRange(sample), ref, pv, pq, flag_lambdaIncrease, lagrange_order);
                times(sample) = toc;
            elseif phase2,
                tic;
                    [mVs, mL] = cpf_predict_lambda(V_corr(:,1:endPt), lambda_corr(1:endPt), lambda_saved, sigmaRange(sample), continuationBus, ref, pv, pq, lagrange_order);
                times(sample) = toc;
            end    
              
                V_lagrange(sample) = abs(mVs(continuationBus));   l_lagrange(sample) = mL;
        end
        
        fprintf('average of %d iterations of lagrange predictor: %f seconds\n', length(sigmaRange), mean(times));

        %plot prediction curves
        hold on; lin_prs = plot(l_linear, V_linear, 'g-.','LineWidth', 2); hold off;
        hold on; lag_prs = plot(l_lagrange, V_lagrange, 'm--','LineWidth', 2); hold off;



        %get linear prediction point at stepSize
        if phase1 || phase3,
            [mVs, mL,~] = cpf_predict(Ybus, ref, pv, pq, V_saved, lambda_saved, stepSize, 1, initQPratio, participation_i, flag_lambdaIncrease);
        elseif phase2,
            [mVs, mL, ~] = cpf_predict(Ybus, ref, pv, pq, V_saved, lambda_saved, stepSize, [2, continuationBus], initQPratio, participation_i,flag_lambdaIncrease);
        end
        hold on; lin_pr = scatter(mL, abs(mVs(continuationBus)), 'c^', 'MarkerFaceColor','c'); hold off;

        %get lagrange prediction point at stepSize
        if phase1 || phase3,
            [mVs, mL] = cpf_predict_voltage(V_corr(:,1:endPt), lambda_corr(1:endPt), lambda_saved, stepSize, ref, pv, pq, flag_lambdaIncrease, lagrange_order);    
        elseif phase2,
            [mVs, mL] = cpf_predict_lambda(V_corr(:,1:endPt), lambda_corr(1:endPt), lambda_saved, stepSize, continuationBus, ref, pv, pq, lagrange_order);
        end
        hold on; lag_pr = scatter(mL, abs(mVs(continuationBus)), 'cv','MarkerFaceColor','c'); hold off;


        %plot solution to correction
        hold on;  plot( [lambda_corr(endPt), lambda], [abs(V_corr(continuationBus,endPt)), abs(V(continuationBus))], 'b')
        hold on; corr = scatter(lambda, abs(V(continuationBus)), 'bs','MarkerFaceColor','b'); hold off;

        %detail the plot
        legend( [prev_pr, prev_corr, lin_prs, lag_prs, lin_pr, lag_pr, corr], ...
                    {
                        'previous predicted voltages',...
                        'previous corrected voltages',...
                        'linear prediction function',...
                        'lagrange prediction function',...
                        'linear prediction',...
                        'lagrange prediction',...
                        'corrected value',...
                    });
        title('Linear Predictor v.s. Lagrange Predictor');
        ylabel('Voltage (p.u.)');
        xlabel('Power (lambda load scaling factor)');
        fprintf('done')
        
        

    end

function [med, idx] =mymedian(x)
% mymedian    Calculate the median value of an array and find its index.
%
% This function can be used to calculate the median value of an array.
% Unlike the built in median function, it returns the index where the
% median value occurs. In cases where the array does not contain its
% median, such as [1,2,3,4] or [1,3,2,4], the index of the first occuring
% adjacent point will be returned; in both of the above examples the median
% will be 2.5 and the index will be 2.

    assert(isvector(x));
    
    
    med = median(x);
    
    [~, idx] = min( abs( x - med));
end



end

%% Changelog - Anton Lodder - 2013.3.27
% I implemented participation factor loading to allow all buses to
% participate in load increase as a function of lambda.
%
% * Participation factors should be given as a vector, one value for each
%   bus.
% * if only one value is given, it is assumed that the value is a bus
%   number rather than a  participation factor, and all other buses get a
%   participation factor of zero (point two)
% * any buses with zero participation factor will remain at their initial
%   load level
% * from the previous two bullets: backwards compatibility is maintained
%   while allowing increased functionality
% * if participation is not a valid bus number (eg float, negative number),
%	maintains given bus loading profile.
% * if no participation factors are given, maintain given bus loading
%   profile.
