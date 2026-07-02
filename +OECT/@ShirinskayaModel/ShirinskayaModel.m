classdef ShirinskayaModel < OECT.Model
    %OECT.SHIRINSKAYAMODEL Shirinskaya PNP+RC model
    
    properties (Access = private)
        sigma_inter
        Vg_lookup
        gm_inter
        VT double
        cache struct = struct()
    end
    
    methods
        function obj = ShirinskayaModel(parameters)
            if nargin < 1
                parameters = OECT.Parameters('Shirinskaya');
            end
            obj@OECT.Model(parameters);
            obj.modelName = 'Shirinskaya';
            obj.logger = OECT.Logger('ShirinskayaModel');
            obj.computeConstants();
        end
        
        function computeConstants(obj)
            obj.VT = (obj.parameters.kB * obj.parameters.T) / obj.parameters.q;
        end
        
        function buildInterpolants(obj, Sigma, Vg_lookup, Vg_vals, Vd_vals, gm)
            obj.sigma_inter = @(Vg) interp1(Vg_lookup, Sigma, Vg, 'pchip', 'extrap');
            obj.Vg_lookup = Vg_lookup;
            obj.gm_inter = griddedInterpolant({Vg_vals, Vd_vals}, gm, 'linear', 'nearest');
        end
        
        function sim = simulate(obj, Vg, t, Vds)
            obj.logger.debug('Simulating with %d time points', length(t));
            obj.checkStop();
            
            Rs = obj.parameters.Rs;
            Rd = obj.parameters.Rd;
            Cd = obj.parameters.Cd;
            
            t = t(:);
            Vg = Vg(:);
            n = length(t);
            
            if isscalar(Vds)
                Vds = Vds * ones(n, 1);
            else
                Vds = Vds(:);
            end
            
            tau = Cd * Rd * Rs / (Rd + Rs);
            dt = t(2) - t(1);
            alpha = exp(-dt / max(tau, 1e-12));
            
            settle_samples = max(round(5 * tau / dt), 10);
            rel_tol = 1e-4;
            abs_tol = 1e-12;
            
            I_out = zeros(n, 1);
            I_current = obj.I_steady(Vg(1), Vds(1));
            I_out(1) = I_current;
            
            stable_count = 0;
            last_Vg = Vg(1);
            last_Vds = Vds(1);
            
            for k = 2:n
                obj.checkStop();
                
                Vg_k = Vg(k);
                Vds_k = Vds(k);
                
                if Vg_k ~= last_Vg || Vds_k ~= last_Vds
                    stable_count = 0;
                    last_Vg = Vg_k;
                    last_Vds = Vds_k;
                end
                
                I_inf = obj.I_steady(Vg_k, Vds_k);
                
                I_prev = I_current;
                I_current = I_inf + (I_current - I_inf) * alpha;
                
                dI = abs(I_current - I_prev);
                I_scale = max(abs(I_current), abs_tol);
                if dI / I_scale < rel_tol
                    stable_count = stable_count + 1;
                else
                    stable_count = 0;
                end
                
                if stable_count >= settle_samples
                    I_current = I_inf;
                    stable_count = 0;
                end
                
                I_out(k) = I_current;
            end
            
            sim.t = t;
            sim.Id = I_out;
            sim.Vgs = Vg;
            sim.Vds = Vds;
            sim.tau = tau;
        end
        
        function I = I_steady(obj, Vg, Vds)
            if abs(Vds) < 1e-12
                I = 0;
            else
                d = obj.parameters.d;
                L = obj.parameters.L;
                W = obj.parameters.W;
                I = -W * d / L * integral(obj.sigma_inter, Vg, Vg - Vds);
            end
        end
        
        function fitResults = fit(obj, data)
            obj.logger.info('Starting Shirinskaya model fit');
            obj.logger.info('Data: %d transient files', length(data.transient.filenames));
            
            conductance = obj.extractConductance(data);
            
            nFiles = length(data.transient.filenames);
            allResults = cell(nFiles, 1);
            
            if obj.canUseParallel()
                obj.logger.info('Using parallel processing');
                parfor i = 1:nFiles
                    allResults{i} = obj.fitSingleFile(data, i, conductance);
                end
            else
                obj.logger.info('Using serial processing');
                for i = 1:nFiles
                    obj.logger.debug('Fitting file %d/%d', i, nFiles);
                    allResults{i} = obj.fitSingleFile(data, i, conductance);
                    if obj.stopFlag
                        break;
                    end
                end
            end
            
            fitResults = obj.aggregateFits(allResults);
            obj.logger.info('Fit complete. R2 = %.4f', fitResults.avgR2);
        end
        
        function conductance = extractConductance(obj, data)
            parsed = data.steadyState.parsed;
            d = obj.parameters.d;
            L = obj.parameters.L;
            W = obj.parameters.W;
            
            [conductance.sigma, conductance.Vg_lookup, conductance.max] = ...
                obj.reconstructSigma(parsed, d, L, W);
            
            obj.Vg_lookup = conductance.Vg_lookup;
            obj.sigma_inter = @(Vg) interp1(conductance.Vg_lookup, conductance.sigma, Vg, 'pchip', 'extrap');
        end
        
        function [sigma, Vg_lookup, sigma_max] = reconstructSigma(obj, parsed, d, L, W)
            Vg = parsed.Vg_sorted;
            Vd = parsed.Vd_sorted;
            Id = parsed.Id_matrix;
            
            Nb = 120;
            Vmin = min(Vg) - min(Vd) - 1e-9;
            Vmax = max(Vg) + 1e-9;
            edges = linspace(Vmin, Vmax, Nb+1)';
            centers = 0.5 * (edges(1:end-1) + edges(2:end));
            
            Iint = -(L/(W*d)) * Id;
            Ivec = Iint(:);
            
            nMeas = numel(Ivec);
            A = zeros(nMeas, Nb);
            
            row = 0;
            for k = 1:length(Vd)
                for j = 1:length(Vg)
                    row = row + 1;
                    a = Vg(j);
                    b = Vg(j) - Vd(k);
                    
                    sgn = sign(b - a);
                    if sgn == 0
                        continue;
                    end
                    
                    lo = min(a,b);
                    hi = max(a,b);
                    
                    left = max(lo, edges(1:end-1));
                    right = min(hi, edges(2:end));
                    overlap = max(0, right - left);
                    
                    A(row, :) = (sgn * overlap).';
                end
            end
            
            lambda_smooth = 1e-3;
            D2 = diff(eye(Nb), 2);
            sigma_bins = (A'*A + lambda_smooth * (D2'*D2)) \ (A'*Ivec);
            
            d_sigma = gradient(sigma_bins, centers);
            abs_d_sigma = abs(d_sigma);
            sigma_peak = max(sigma_bins);
            d_sigma_norm = abs_d_sigma / sigma_peak;
            
            plateau_threshold = 0.05;
            plateau_mask = d_sigma_norm < plateau_threshold;
            
            if any(plateau_mask)
                sigma_plateau = sigma_bins(plateau_mask);
                sigma_max = median(sigma_plateau(sigma_plateau > 0.5 * sigma_peak));
                if isnan(sigma_max) || isempty(sigma_max)
                    sigma_max = max(sigma_plateau);
                end
            else
                sigma_max = sigma_peak;
            end
            
            sigma = sigma_bins / sigma_max;
            Vg_lookup = centers;
        end
        
        function result = fitSingleFile(obj, data, idx, conductance)
            parsed = data.transient.parsed{idx};
            
            Vgs = parsed.filename_Vgs;
            if isnan(Vgs)
                Vgs = mean(parsed.Vgs);
            end
            Vds = parsed.filename_Vds;
            if isnan(Vds)
                Vds = mean(parsed.Vds);
            end
            
            gm_val = obj.gm_inter(Vgs, Vds);
            I0 = obj.I_steady(Vgs, Vds);
            
            t = parsed.time;
            Id = parsed.drainCurrent;
            
            t_clean = t(t > 0 & isfinite(Id));
            Id_clean = Id(t > 0 & isfinite(Id));
            
            if length(t_clean) < 50
                result = obj.createFailedResult('Not enough data points');
                return;
            end
            
            t_fit = logspace(log10(min(t_clean)), log10(max(t_clean)), 250)';
            Id_fit = interp1(t_clean, Id_clean, t_fit, 'pchip');
            
            weights = 1 ./ sqrt(t_fit + 1e-6);
            weights = weights / median(weights);
            tail_start = round(0.9 * length(t_fit));
            weights(tail_start:end) = weights(tail_start:end) * 10;
            weights = weights / mean(weights);
            
            try
                [p_opt, ~] = obj.fitRC(t_fit, Id_fit, Vgs, Vds, gm_val, I0, weights);
                
                [fit_curve, tau] = obj.evaluateRC(p_opt, t_fit, Vgs, Vds, gm_val, I0);
                metrics = obj.computeFitMetrics(Id_fit, fit_curve);
                
                result = struct();
                result.Rs = p_opt(1);
                result.Rd = p_opt(2);
                result.Cd = p_opt(3);
                result.f = p_opt(4);
                result.tau = tau;
                result.R2 = metrics.R2;
                result.RMSE = metrics.RMSE;
                result.NRMSE = metrics.NRMSE;
                result.success = true;
                result.Vgs = Vgs;
                result.Vds = Vds;
                
            catch ME
                obj.logger.warn('Fit failed for file %d: %s', idx, ME.message);
                result = obj.createFailedResult(ME.message);
            end
        end
        
        function [p_opt, info] = fitRC(obj, t, Id, Vgs, Vds, gm_val, I0, weights)
            % Fit RC model parameters
            
            lb = [1, 1, 1e-12, 0];
            ub = [1e7, 1e9, 1, 1];
            p0 = [2e3, 15e4, 3e-3, 0.5];
            
            % Model function
            function I = rc_model(p)
                Rs = p(1);
                Rd = p(2);
                Cd = p(3);
                f = p(4);
                
                tau = Cd * Rd * Rs / (Rd + Rs);
                if ~isfinite(tau) || tau <= 0
                    I = nan(size(t));
                    return;
                end
                
                term_1 = Vgs * (gm_val * Rd - f) / (Rd + Rs);
                term_2 = Vgs * Rd * (gm_val * Rs + f) / (Rs * Rd + Rs * Rs);
                I = I0 + term_1 - term_2 .* exp(-t ./ tau);
            end
            
            % Residual
            function r = residual(p)
                I = rc_model(p);
                if any(~isfinite(I))
                    r = 1e6 * ones(size(Id));
                else
                    r = (I - Id) .* weights;
                end
            end
            
            options = optimoptions('lsqnonlin', 'Display', 'off', ...
                'MaxIterations', 800, 'MaxFunctionEvaluations', 20000);
            
            problem = createOptimProblem('lsqnonlin', ...
                'x0', p0, ...
                'objective', @residual, ...
                'lb', lb, ...
                'ub', ub, ...
                'options', options);
            
            % MultiStart
            nStarts = 100;
            startPoints = zeros(nStarts, 4);
            
            rng(1);
            for k = 1:nStarts
                widen = 1 + (k-1)/(nStarts-1) * 3;
                Rs0 = p0(1) * 10.^((randn * 0.25) * widen);
                Rd0 = p0(2) * 10.^((randn * 0.25) * widen);
                Rs0 = min(max(Rs0, lb(1)), ub(1));
                Rd0 = min(max(Rd0, lb(2)), ub(2));
                
                tmax = max(t);
                tau_target = min(max(0.1 * tmax, 1e-6), 10 * tmax);
                Cd0 = tau_target * (Rd0 + Rs0) / (Rd0 * Rs0);
                Cd0 = min(max(Cd0, lb(3)), ub(3));
                
                startPoints(k,:) = [Rs0, Rd0, Cd0, rand];
            end
            
            ms = MultiStart('Display', 'off', 'UseParallel', false);
            sp = CustomStartPointSet(startPoints);
            [p_opt, ~, exitflag, output] = run(ms, problem, sp);
            
            info.exitflag = exitflag;
            info.iterations = output.iterations;
            info.funcCount = output.funcCount;
        end
        
        function [Id_fit, tau] = evaluateRC(obj, p, t, Vgs, Vds, gm_val, I0)
            % Evaluate RC model
            Rs = p(1);
            Rd = p(2);
            Cd = p(3);
            f = p(4);
            
            tau = Cd * Rd * Rs / (Rd + Rs);
            term_1 = Vgs * (gm_val * Rd - f) / (Rd + Rs);
            term_2 = Vgs * Rd * (gm_val * Rs + f) / (Rs * Rd + Rs * Rs);
            Id_fit = I0 + term_1 - term_2 .* exp(-t ./ tau);
        end
        
        function can = canUseParallel(obj)
            can = license('test', 'Distrib_Computing_Toolbox') && ...
                  ~isempty(ver('parallel'));
        end
        
        function result = createFailedResult(obj, message)
            result = struct();
            result.success = false;
            result.error = message;
            result.R2 = -Inf;
            result.RMSE = Inf;
            result.NRMSE = Inf;
        end
        
        function metrics = computeFitMetrics(obj, y_true, y_pred)
            res = y_true - y_pred;
            metrics.RMSE = sqrt(mean(res.^2));
            metrics.MAE = mean(abs(res));
            metrics.MaxErr = max(abs(res));
            metrics.NRMSE = metrics.RMSE / (max(y_true) - min(y_true) + eps);
            metrics.R2 = 1 - sum(res.^2) / (sum((y_true - mean(y_true)).^2) + eps);
        end
        
        function fitResults = aggregateFits(obj, allResults)
            % FIX: allResults is a cell array
            success_mask = cellfun(@(r) isstruct(r) && isfield(r,'success') && r.success, allResults);
            good_idx = find(success_mask);
            
            fitResults = struct();
            fitResults.n_total = numel(allResults);
            fitResults.n_success = numel(good_idx);
            fitResults.n_failed = fitResults.n_total - fitResults.n_success;
            
            if isempty(good_idx)
                obj.logger.warn('No successful fits');
                fitResults.avgR2 = -Inf;
                fitResults.parameters = obj.parameters;
                return;
            end
            
            Rs_vals = cellfun(@(r) r.Rs, allResults(good_idx));
            Rd_vals = cellfun(@(r) r.Rd, allResults(good_idx));
            Cd_vals = cellfun(@(r) r.Cd, allResults(good_idx));
            f_vals = cellfun(@(r) r.f, allResults(good_idx));
            R2_vals = cellfun(@(r) r.R2, allResults(good_idx));
            
            fitResults.avg_Rs = median(Rs_vals);
            fitResults.avg_Rd = median(Rd_vals);
            fitResults.avg_Cd = median(Cd_vals);
            fitResults.avg_f = median(f_vals);
            fitResults.avgR2 = median(R2_vals);
            
            fitResults.std_Rs = std(Rs_vals);
            fitResults.std_Rd = std(Rd_vals);
            fitResults.std_Cd = std(Cd_vals);
            fitResults.std_f = std(f_vals);
            
            obj.parameters.params.Rs = fitResults.avg_Rs;
            obj.parameters.params.Rd = fitResults.avg_Rd;
            obj.parameters.params.Cd = fitResults.avg_Cd;
            obj.parameters.params.f = fitResults.avg_f;
            
            fitResults.parameters = obj.parameters;
            fitResults.all_results = allResults(good_idx);
            fitResults.good_idx = good_idx;
        end
    end
end