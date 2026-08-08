classdef (Abstract) ImpedanceModel < OECT.Model
    %OECT.IMPEDANCEMODEL  Abstract base class for EIS circuit impedance models.
    %
    %  Holds the multi-start fitting engine (Latin-Hypercube Sampling +
    %  fmincon, polished with lsqnonlin) and the Nyquist/Bode/Residuals
    %  plotting infrastructure shared by every equivalent-circuit topology
    %  used to fit gate-source-shorted EIS data. Concrete subclasses only
    %  need to supply the circuit equation and parameter set:
    %
    %    OECT.ImpedanceGSModel      - Impedance (GS shortcut)
    %                                 Z = r + {[R2||(1/(Q2*(jw)^n2))] +
    %                                 [A/(jw)^nW] + [R1||(1/(Q1*(jw)^n1))] +
    %                                 R3 + r} || [R0+jwL0+r] + Rload
    %    OECT.ImpedanceSDModel      - Impedance (Source to Drain)
    %                                 Z = Rs + [Rchannel||(Rpore+
    %                                 1/(Q_vol*(jw)^n))]
    %    OECT.ImpedanceSDShortModel - Impedance (SD shortcut)
    %                                 Z = R3+[R1||1/(jwC1)]+[1/(Q0*(jw)^n)]+
    %                                 r+[R2||1/(jwC2)]

    properties (Access = protected)
        Rload double = 500          % fixed load resistance (Ohm)
        eisData struct = struct()   % last loaded EIS data
    end

    % ------------------------------------------------------------------ %
    methods
        function obj = ImpedanceModel(parameters)
            if nargin < 1
                parameters = OECT.Parameters('Impedance_GS');
            end
            obj@OECT.Model(parameters);
            obj.logger = OECT.Logger(class(obj));
            obj.modelName = obj.getModelName();
        end

        % ----------------------------------------------------------------
        %  CORE INTERFACE (required by OECT.Model)
        % ----------------------------------------------------------------
        function sim = simulate(obj, Vg, t, Vds)
            %SIMULATE  Stub – not meaningful for an EIS-only model.
            obj.logger.warn('simulate() is not implemented for impedance models');
            t   = t(:);  Vg = Vg(:);
            n   = length(t);
            Vds = Vds * ones(n,1);
            sim.t   = t;
            sim.Id  = zeros(n,1);
            sim.Vgs = Vg;
            sim.Vds = Vds;
        end

        function fitResults = fit(obj, eisData, fitOptions)
            %FIT  Multi-start EIS fitting (shared by every circuit topology).
            %
            %  fitResults = obj.fit(eisData)
            %  fitResults = obj.fit(eisData, fitOptions)
            %
            %  eisData    : struct with fields frequency, Z_real, Z_imag
            %               (as returned by ImpedanceDataLoader.getData())
            %  fitOptions : optional struct with fields
            %                 nStarts  (default 50)
            %                 maxIter  (default 500)
            %                 tol      (default 1e-8)
            %                 verbose  (default false)
            %                 useParallel (default false)
            %                 progressFcn  – callback(start, nStarts, bestR2)

            if nargin < 3 || isempty(fitOptions)
                fitOptions = struct();
            end
            fitOptions = obj.mergeDefaults(fitOptions);

            obj.eisData  = eisData;
            frequencies  = eisData.frequency(:);
            Z_meas       = eisData.Z_real(:) + 1i * eisData.Z_imag(:);
            w_vec        = 2*pi*frequencies;

            obj.logger.info('Starting EIS fit: %d points, %d starts', ...
                length(frequencies), fitOptions.nStarts);

            % Parameter bounds (order given by obj.getParameterNames(); the
            % defaults below are overridable per-parameter via
            % obj.parameters.setParamBounds, e.g. from the GUI's fitting
            % range columns)
            paramOrder = obj.getParameterNames();
            boundsStruct = obj.getParameterBounds();
            lb = zeros(1, numel(paramOrder));
            ub = zeros(1, numel(paramOrder));
            for k = 1:numel(paramOrder)
                b = boundsStruct.(paramOrder{k});
                lb(k) = b(1);
                ub(k) = b(2);
            end

            % Build initial guesses via LHS
            guesses = obj.latinHypercubeSampling(fitOptions.nStarts, lb, ub);

            allResults = cell(fitOptions.nStarts, 1);
            bestR2     = -Inf;

            % Bind the concrete circuit equation (a Static method resolved
            % on the subclass) into a plain function handle, so the
            % fitting engine below stays circuit-agnostic and parfor-safe.
            modelClass = class(obj);
            Rload_val  = obj.Rload;
            circuitFcn = @(w_vec_, p) feval([modelClass '.circuitImpedance'], w_vec_, p, Rload_val);

            if fitOptions.useParallel && obj.canUseParallel()
                obj.logger.info('Using parallel processing');
                parfor s = 1:fitOptions.nStarts
                    allResults{s} = OECT.ImpedanceModel.fitSingleStart( ...
                        guesses(s,:), lb, ub, w_vec, Z_meas, circuitFcn, fitOptions);
                end
            else
                for s = 1:fitOptions.nStarts
                    obj.checkStop();
                    allResults{s} = OECT.ImpedanceModel.fitSingleStart( ...
                        guesses(s,:), lb, ub, w_vec, Z_meas, circuitFcn, fitOptions);

                    if allResults{s}.success && allResults{s}.R2 > bestR2
                        bestR2 = allResults{s}.R2;
                    end
                    if fitOptions.verbose
                        obj.logger.debug('Start %d/%d | current R2=%.4f | best R2=%.4f', ...
                            s, fitOptions.nStarts, allResults{s}.R2, bestR2);
                    end
                    if isfield(fitOptions, 'progressFcn') && ~isempty(fitOptions.progressFcn)
                        fitOptions.progressFcn(s, fitOptions.nStarts, bestR2);
                    end
                end
            end

            fitResults = obj.aggregateFits(allResults, w_vec, Z_meas, circuitFcn);
            obj.logger.info('Fit complete. R2 = %.4f (best of %d starts)', ...
                fitResults.avgR2, fitOptions.nStarts);
        end

        % ----------------------------------------------------------------
        %  IMPEDANCE CALCULATION
        % ----------------------------------------------------------------
        function Z = computeImpedanceVec(obj, w_vec, p)
            %COMPUTEIMPEDANCEVEC  Vectorised circuit impedance (dispatches
            %  to the concrete subclass's circuitImpedance implementation).
            Z = obj.circuitImpedance(w_vec, p, obj.Rload);
        end

        % ----------------------------------------------------------------
        %  VISUALISATION
        % ----------------------------------------------------------------
        function plotNyquist(obj, ax, eisData, fitResults)
            %PLOTNYQUIST  Nyquist diagram (experimental + fitted).
            if nargin < 2 || isempty(ax), ax = axes(); end

            Z_meas = eisData.Z_real + 1i * eisData.Z_imag;

            plot(ax, real(Z_meas), -imag(Z_meas), 'o', ...
                'MarkerSize', 4, 'Color', [0.3 0.6 1], 'DisplayName', 'Experiment');
            hold(ax, 'on');

            if nargin >= 4 && ~isempty(fitResults) && isfield(fitResults, 'bestParams')
                p    = fitResults.bestParams;
                w_f  = 2*pi*eisData.frequency;
                Z_fit = obj.computeImpedanceVec(w_f, p);
                plot(ax, real(Z_fit), -imag(Z_fit), '-', ...
                    'LineWidth', 1.5, 'Color', [1 0.4 0.1], 'DisplayName', 'Fit');
            end

            hold(ax, 'off');
            xlabel(ax, 'Z_{real} (\Omega)');
            ylabel(ax, '-Z_{imag} (\Omega)');
            title(ax, 'Nyquist Plot');
            legend(ax, 'Location', 'best');
            grid(ax, 'on');
            axis(ax, 'equal');
        end

        function plotBode(obj, axMag, axPhase, eisData, fitResults)
            %PLOTBODE  Bode magnitude and phase plots.
            freq = eisData.frequency;
            Z_meas = eisData.Z_real + 1i * eisData.Z_imag;

            % Magnitude
            semilogx(axMag, freq, 20*log10(abs(Z_meas)), 'o', ...
                'MarkerSize', 4, 'Color', [0.3 0.6 1], 'DisplayName', 'Experiment');
            hold(axMag, 'on');
            ylabel(axMag, '|Z| (dB\Omega)');
            title(axMag, 'Bode – Magnitude');
            grid(axMag, 'on');

            % Phase
            semilogx(axPhase, freq, angle(Z_meas)*180/pi, 'o', ...
                'MarkerSize', 4, 'Color', [0.3 0.6 1], 'DisplayName', 'Experiment');
            hold(axPhase, 'on');
            ylabel(axPhase, 'Phase (deg)');
            xlabel(axPhase, 'Frequency (Hz)');
            title(axPhase, 'Bode – Phase');
            grid(axPhase, 'on');

            if nargin >= 5 && ~isempty(fitResults) && isfield(fitResults, 'bestParams')
                p    = fitResults.bestParams;
                w_f  = 2*pi*freq;
                Z_fit = obj.computeImpedanceVec(w_f, p);
                semilogx(axMag, freq, 20*log10(abs(Z_fit)), '-', ...
                    'LineWidth', 1.5, 'Color', [1 0.4 0.1], 'DisplayName', 'Fit');
                semilogx(axPhase, freq, angle(Z_fit)*180/pi, '-', ...
                    'LineWidth', 1.5, 'Color', [1 0.4 0.1], 'DisplayName', 'Fit');
            end

            hold(axMag, 'off');   legend(axMag,   'Location', 'best');
            hold(axPhase, 'off'); legend(axPhase, 'Location', 'best');
        end

        function plotResiduals(obj, ax, eisData, fitResults)
            %PLOTRESIDUALS  Relative residuals vs frequency.
            if nargin < 2 || isempty(ax), ax = axes(); end
            if ~isfield(fitResults, 'bestParams'), return; end

            freq  = eisData.frequency;
            Z_m   = eisData.Z_real + 1i * eisData.Z_imag;
            Z_fit = obj.computeImpedanceVec(2*pi*freq, fitResults.bestParams);
            res   = (Z_m - Z_fit) ./ abs(Z_m) * 100;

            semilogx(ax, freq, real(res), '-o', 'MarkerSize', 3, ...
                'DisplayName', 'Real residual');
            hold(ax, 'on');
            semilogx(ax, freq, imag(res), '-s', 'MarkerSize', 3, ...
                'DisplayName', 'Imag residual');
            hold(ax, 'off');
            yline(ax, 0, '--k');
            xlabel(ax, 'Frequency (Hz)');
            ylabel(ax, 'Residual (%)');
            title(ax, 'Relative Residuals');
            legend(ax, 'Location', 'best');
            grid(ax, 'on');
        end

        % ----------------------------------------------------------------
        %  MODEL INTERFACE (required by OECT.Model, generic across circuits)
        % ----------------------------------------------------------------
        function [Vg, Id, gm] = transferCharacteristics(obj, Vg_range, ~)
            Id  = zeros(size(Vg_range));
            gm  = zeros(size(Vg_range));
            Vg  = Vg_range;
        end

        function [Vd, Id] = outputCharacteristics(obj, ~, Vd_range)
            Id = zeros(size(Vd_range));
            Vd = Vd_range;
        end
    end

    % ------------------------------------------------------------------ %
    methods (Abstract)
        % Circuit-specific human-readable info
        name = getModelName(obj)
        description = getModelDescription(obj)

        % Circuit-specific parameter set
        paramNames = getParameterNames(obj)
        bounds = getParameterBounds(obj)
    end

    methods (Abstract, Static)
        % Circuit-specific impedance equation.
        %  Z = circuitImpedance(w_vec, p, Rload)
        %  p is ordered per the concrete subclass's getParameterNames().
        Z = circuitImpedance(w_vec, p, Rload)
    end

    % ------------------------------------------------------------------ %
    methods (Access = protected)
        function opts = mergeDefaults(~, opts)
            if ~isfield(opts, 'nStarts'),     opts.nStarts     = 50;    end
            if ~isfield(opts, 'maxIter'),     opts.maxIter     = 500;   end
            if ~isfield(opts, 'tol'),         opts.tol         = 1e-8;  end
            if ~isfield(opts, 'verbose'),     opts.verbose     = false;  end
            if ~isfield(opts, 'useParallel'), opts.useParallel = false;  end
            if ~isfield(opts, 'progressFcn'), opts.progressFcn = [];    end
        end

        function guesses = latinHypercubeSampling(~, n, lb, ub)
            %LATINHYPERCUBESAMPLING  Generate n parameter vectors in [lb, ub] via LHS.
            np = length(lb);
            if exist('lhsdesign', 'file')
                % Statistics and Machine Learning Toolbox
                unit = lhsdesign(n, np);
            else
                % Fallback: random permutation LHS
                unit = zeros(n, np);
                for k = 1:np
                    perm = randperm(n);
                    unit(:,k) = (perm' - rand(n,1)) / n;
                end
            end
            % Map to log-space for parameters spanning many decades
            guesses = zeros(n, np);
            for k = 1:np
                log_lb = log10(max(lb(k), 1e-15));
                log_ub = log10(ub(k));
                guesses(:,k) = 10.^(log_lb + unit(:,k) * (log_ub - log_lb));
            end
        end

        function fitResults = aggregateFits(obj, allResults, w_vec, Z_meas, circuitFcn)
            success_mask = cellfun(@(r) r.success, allResults);
            good_idx     = find(success_mask);

            fitResults.n_total   = length(allResults);
            fitResults.n_success = length(good_idx);
            fitResults.n_failed  = fitResults.n_total - fitResults.n_success;
            fitResults.all_results = allResults;

            if isempty(good_idx)
                obj.logger.warn('No successful fits');
                fitResults.avgR2      = -Inf;
                fitResults.bestParams = obj.defaultParams();
                fitResults.parameters = obj.parameters;
                return;
            end

            R2_vals = cellfun(@(r) r.R2, allResults(good_idx));
            [~, best_local] = max(R2_vals);
            best_idx = good_idx(best_local);

            fitResults.bestParams = allResults{best_idx}.params;
            fitResults.avgR2      = allResults{best_idx}.R2;
            fitResults.RMSE       = allResults{best_idx}.RMSE;
            fitResults.chiSquared = allResults{best_idx}.chiSquared;

            % Store in Parameters object
            pNames = obj.getParameterNames();
            for k = 1:length(pNames)
                if isfield(obj.parameters.params, pNames{k})
                    obj.parameters.setParameter(pNames{k}, fitResults.bestParams(k));
                end
            end
            fitResults.parameters = obj.parameters;

            % Fitted impedance
            Z_fit = circuitFcn(w_vec, fitResults.bestParams);
            fitResults.Z_fit_real = real(Z_fit);
            fitResults.Z_fit_imag = imag(Z_fit);

            obj.logger.info('Best fit: R2=%.4f, RMSE=%.4e', fitResults.avgR2, fitResults.RMSE);
            obj.logParameters(fitResults.bestParams);
        end

        function p = defaultParams(obj)
            prm = obj.parameters.params;
            fNames = obj.getParameterNames();
            defaults = obj.defaultParamValues();
            p = zeros(1, numel(fNames));
            for k = 1:numel(fNames)
                if isfield(prm, fNames{k})
                    p(k) = prm.(fNames{k});
                else
                    p(k) = defaults(k);
                end
            end
        end

        function logParameters(obj, p)
            names = obj.getParameterNames();
            units = obj.paramUnits();
            for k = 1:length(names)
                obj.logger.info('  %s = %.4e %s', names{k}, p(k), units{k});
            end
        end

        function can = canUseParallel(~)
            can = license('test', 'Distrib_Computing_Toolbox') && ...
                  ~isempty(ver('parallel'));
        end
    end

    methods (Abstract, Access = protected)
        % Fallback initial-guess values (same order as getParameterNames())
        % used whenever obj.parameters.params doesn't already define a
        % parameter.
        defaults = defaultParamValues(obj)

        % Units for each parameter (same order as getParameterNames()),
        % used only for logging.
        units = paramUnits(obj)
    end

    % ------------------------------------------------------------------ %
    methods (Static, Access = private)
        function result = fitSingleStart(x0, lb, ub, w_vec, Z_meas, circuitFcn, opts)
            %FITSINGLESTART  One optimisation run from a given starting point.
            result.success = false;
            result.R2      = -Inf;
            result.RMSE    = Inf;
            result.chiSquared = Inf;
            result.params  = x0;

            objective = @(p) OECT.ImpedanceModel.residualVec(p, w_vec, Z_meas, circuitFcn);

            try
                fminOpts = optimoptions('fmincon', ...
                    'Display',              'off', ...
                    'Algorithm',            'interior-point', ...
                    'MaxIterations',        opts.maxIter, ...
                    'MaxFunctionEvaluations', opts.maxIter * 20, ...
                    'OptimalityTolerance',  opts.tol, ...
                    'StepTolerance',        opts.tol * 1e-3, ...
                    'SpecifyObjectiveGradient', false);

                [p_opt, fval, exitflag] = fmincon( ...
                    @(p) sum(objective(p).^2), ...
                    x0, [], [], [], [], lb, ub, [], fminOpts);

                % Polish the fmincon solution with lsqnonlin, which is
                % specifically designed for nonlinear least-squares problems
                % (like this complex-impedance residual) and often escapes
                % the shallow local optima that a generic constrained
                % optimizer such as fmincon settles into.
                if exitflag >= 0
                    try
                        lsqOpts = optimoptions('lsqnonlin', ...
                            'Display',              'off', ...
                            'Algorithm',            'trust-region-reflective', ...
                            'MaxIterations',        opts.maxIter, ...
                            'MaxFunctionEvaluations', opts.maxIter * 20, ...
                            'FunctionTolerance',    opts.tol, ...
                            'StepTolerance',        opts.tol * 1e-3);

                        [p_polished, res_polished] = lsqnonlin( ...
                            objective, p_opt, lb, ub, lsqOpts);

                        if sum(res_polished.^2) < sum(objective(p_opt).^2)
                            p_opt = p_polished;
                        end
                    catch
                        % lsqnonlin unavailable/failed – keep fmincon result
                    end

                    Z_fit = circuitFcn(w_vec, p_opt);
                    res   = Z_meas - Z_fit;
                    ss_res = sum(abs(res).^2);
                    ss_tot = sum(abs(Z_meas - mean(Z_meas)).^2);
                    R2    = 1 - ss_res / (ss_tot + eps);
                    RMSE  = sqrt(mean(abs(res).^2));
                    chi2  = sum(abs(res ./ abs(Z_meas + eps)).^2);

                    result.success    = true;
                    result.params     = p_opt;
                    result.R2         = R2;
                    result.RMSE       = RMSE;
                    result.chiSquared = chi2;
                    result.fval       = fval;
                    result.exitflag   = exitflag;
                end
            catch ME
                result.error = ME.message;
            end
        end

        function r = residualVec(p, w_vec, Z_meas, circuitFcn)
            %RESIDUALVEC  Complex relative residual vector for lsqnonlin / sum-of-squares.
            Z_fit = circuitFcn(w_vec, p);
            denom = abs(Z_meas) + eps;
            r = [real(Z_meas - Z_fit) ./ denom; imag(Z_meas - Z_fit) ./ denom];
        end
    end
end
