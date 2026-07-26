classdef ImpedanceModel < OECT.Model
    %OECT.IMPEDANCEMODEL  EIS impedance model for gate-source shorted OECT
    %
    %  Circuit topology (gate-source shorted, 10 mM CaCl2):
    %
    %  Z = r + { [R2||(1/jwC2)] + [(1-j)*A/sqrt(w)] +
    %            [R1||(1/jwC1)] + R3 + r }  ||  [R0 + jwL0 + r]  +  Rload
    %
    %  Free parameters  : R0, L0, C1, R1, C2, R2, A, r, R3
    %  Fixed parameters : Rload = 500 Ohm
    %
    %  Multi-start fitting uses Latin-Hypercube Sampling (LHS) to generate
    %  initial guesses and fmincon (with GlobalSearch when available) to
    %  minimise a weighted complex-impedance residual.
    
    properties (Access = private)
        Rload double = 500          % fixed load resistance (Ohm)
        eisData struct = struct()   % last loaded EIS data
    end

    % ------------------------------------------------------------------ %
    methods
        function obj = ImpedanceModel(parameters)
            if nargin < 1
                parameters = OECT.Parameters('Impedance');
            end
            obj@OECT.Model(parameters);
            obj.modelName = 'Impedance';
            obj.logger = OECT.Logger('ImpedanceModel');
        end

        % ----------------------------------------------------------------
        %  CORE INTERFACE (required by OECT.Model)
        % ----------------------------------------------------------------
        function sim = simulate(obj, Vg, t, Vds)
            %SIMULATE  Stub – not meaningful for an EIS-only model.
            obj.logger.warn('simulate() is not implemented for the impedance model');
            t   = t(:);  Vg = Vg(:);
            n   = length(t);
            Vds = Vds * ones(n,1);
            sim.t   = t;
            sim.Id  = zeros(n,1);
            sim.Vgs = Vg;
            sim.Vds = Vds;
        end

        function fitResults = fit(obj, eisData, fitOptions)
            %FIT  Multi-start EIS fitting.
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

            % Parameter bounds  [R0  L0   C1   R1   C2   R2   A    r    R3]
            lb = [1e-3, 1e-12, 1e-12, 1e-3, 1e-12, 1e-3, 1e-6, 1e-3, 0    ];
            ub = [1e6,  1e-1,  1e-1,  1e6,  1e-1,  1e6,  1e8,  1e5,  1e6  ];

            % Build initial guesses via LHS
            guesses = obj.latinHypercubeSampling(fitOptions.nStarts, lb, ub);

            allResults = cell(fitOptions.nStarts, 1);
            bestR2     = -Inf;

            if fitOptions.useParallel && obj.canUseParallel()
                obj.logger.info('Using parallel processing');
                % parallel loop – capture variables needed inside parfor
                Rload_val = obj.Rload;
                parfor s = 1:fitOptions.nStarts
                    allResults{s} = OECT.ImpedanceModel.fitSingleStart( ...
                        guesses(s,:), lb, ub, w_vec, Z_meas, Rload_val, fitOptions);
                end
            else
                for s = 1:fitOptions.nStarts
                    obj.checkStop();
                    allResults{s} = OECT.ImpedanceModel.fitSingleStart( ...
                        guesses(s,:), lb, ub, w_vec, Z_meas, obj.Rload, fitOptions);

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

            fitResults = obj.aggregateFits(allResults, w_vec, Z_meas);
            obj.logger.info('Fit complete. R2 = %.4f (best of %d starts)', ...
                fitResults.avgR2, fitOptions.nStarts);
        end

        % ----------------------------------------------------------------
        %  IMPEDANCE CALCULATION
        % ----------------------------------------------------------------
        function Z = computeImpedanceVec(obj, w_vec, p)
            %COMPUTEIMPEDANCEVEC  Vectorised circuit impedance.
            %  p = [R0 L0 C1 R1 C2 R2 A r R3]
            Z = OECT.ImpedanceModel.circuitImpedance(w_vec, p, obj.Rload);
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
                Z_fit = OECT.ImpedanceModel.circuitImpedance(w_f, p, obj.Rload);
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
                Z_fit = OECT.ImpedanceModel.circuitImpedance(w_f, p, obj.Rload);
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
            Z_fit = OECT.ImpedanceModel.circuitImpedance(2*pi*freq, fitResults.bestParams, obj.Rload);
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
        %  MODEL INTERFACE (required by OECT.Model)
        % ----------------------------------------------------------------
        function name = getModelName(obj)
            name = 'Impedance';
        end

        function description = getModelDescription(obj)
            description = ['EIS impedance model for gate-source shorted OECT. ' ...
                'Circuit: Z = r + {[R2||(1/jwC2)] + [(1-j)*A/sqrt(w)] + ' ...
                '[R1||(1/jwC1)] + R3 + r} || [R0+jwL0+r] + Rload'];
        end

        function paramNames = getParameterNames(obj)
            paramNames = {'R0','L0','C1','R1','C2','R2','A','r','R3'};
        end

        function bounds = getParameterBounds(obj)
            bounds = struct( ...
                'R0',  [1e-3, 1e6], ...
                'L0',  [1e-12, 1e-1], ...
                'C1',  [1e-12, 1e-1], ...
                'R1',  [1e-3, 1e6], ...
                'C2',  [1e-12, 1e-1], ...
                'R2',  [1e-3, 1e6], ...
                'A',   [1e-6, 1e8], ...
                'r',   [1e-3, 1e5], ...
                'R3',  [0, 1e6]);
        end

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
    methods (Access = private)
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

        function fitResults = aggregateFits(obj, allResults, w_vec, Z_meas)
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
            pNames = {'R0','L0','C1','R1','C2','R2','A','r','R3'};
            for k = 1:length(pNames)
                if isfield(obj.parameters.params, pNames{k})
                    obj.parameters.params.(pNames{k}) = fitResults.bestParams(k);
                end
            end
            fitResults.parameters = obj.parameters;

            % Fitted impedance
            Z_fit = OECT.ImpedanceModel.circuitImpedance(w_vec, fitResults.bestParams, obj.Rload);
            fitResults.Z_fit_real = real(Z_fit);
            fitResults.Z_fit_imag = imag(Z_fit);

            obj.logger.info('Best fit: R2=%.4f, RMSE=%.4e', fitResults.avgR2, fitResults.RMSE);
            obj.logParameters(fitResults.bestParams);
        end

        function p = defaultParams(obj)
            prm = obj.parameters.params;
            fNames = {'R0','L0','C1','R1','C2','R2','A','r','R3'};
            defaults = [1000, 1e-6, 1e-6, 500, 1e-7, 2000, 1e4, 100, 50];
            p = zeros(1,9);
            for k = 1:9
                if isfield(prm, fNames{k})
                    p(k) = prm.(fNames{k});
                else
                    p(k) = defaults(k);
                end
            end
        end

        function logParameters(obj, p)
            names    = {'R0','L0','C1','R1','C2','R2','A','r','R3'};
            units    = {'Ohm','H','F','Ohm','F','Ohm','Ohm.s^-0.5','Ohm','Ohm'};
            for k = 1:length(names)
                obj.logger.info('  %s = %.4e %s', names{k}, p(k), units{k});
            end
        end

        function can = canUseParallel(~)
            can = license('test', 'Distrib_Computing_Toolbox') && ...
                  ~isempty(ver('parallel'));
        end
    end

    % ------------------------------------------------------------------ %
    methods (Static, Access = private)
        function Z = circuitImpedance(w_vec, p, Rload)
            %CIRCUITIMPEDANCE  Vectorised circuit evaluation.
            %  p = [R0, L0, C1, R1, C2, R2, A, r, R3]
            R0 = p(1); L0 = p(2); C1 = p(3); R1 = p(4);
            C2 = p(5); R2 = p(6); A  = p(7); r  = p(8); R3 = p(9);

            w = w_vec(:);

            Z_C1  = 1 ./ (1i * w * C1);
            Z_C2  = 1 ./ (1i * w * C2);
            Z_RC1 = (R1 .* Z_C1) ./ (R1 + Z_C1);   % R1 || C1
            Z_RC2 = (R2 .* Z_C2) ./ (R2 + Z_C2);   % R2 || C2
            Z_W   = (1 - 1i) * A ./ sqrt(w);        % Warburg

            Z_arm1 = Z_RC2 + Z_W + Z_RC1 + R3 + r; % ionic/channel arm
            Z_arm2 = R0 + 1i * w * L0 + r;          % inductive arm

            Z_par = (Z_arm1 .* Z_arm2) ./ (Z_arm1 + Z_arm2);
            Z = r + Z_par + Rload;
        end

        function result = fitSingleStart(x0, lb, ub, w_vec, Z_meas, Rload, opts)
            %FITSINGLESTART  One optimisation run from a given starting point.
            result.success = false;
            result.R2      = -Inf;
            result.RMSE    = Inf;
            result.chiSquared = Inf;
            result.params  = x0;

            objective = @(p) OECT.ImpedanceModel.residualVec(p, w_vec, Z_meas, Rload);

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

                if exitflag >= 0
                    Z_fit = OECT.ImpedanceModel.circuitImpedance(w_vec, p_opt, Rload);
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

        function r = residualVec(p, w_vec, Z_meas, Rload)
            %RESIDUALVEC  Complex relative residual vector for lsqnonlin / sum-of-squares.
            Z_fit = OECT.ImpedanceModel.circuitImpedance(w_vec, p, Rload);
            denom = abs(Z_meas) + eps;
            r = [real(Z_meas - Z_fit) ./ denom; imag(Z_meas - Z_fit) ./ denom];
        end
    end
end
