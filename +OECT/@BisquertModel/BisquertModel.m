classdef BisquertModel < OECT.Model
    %OECT.BISQUERTMODEL Bisquert ionic dynamics model
    
    properties (Access = private)
        VT double
        cache struct = struct()
    end
    
    methods
        function obj = BisquertModel(parameters)
            if nargin < 1
                parameters = OECT.Parameters('Bisquert');
            end
            obj@OECT.Model(parameters);
            obj.modelName = 'Bisquert';
            obj.logger = OECT.Logger('BisquertModel');
            obj.computeConstants();
        end
        
        function computeConstants(obj)
            obj.VT = (obj.parameters.kB * obj.parameters.T) / obj.parameters.q;
        end
        
        function sim = simulate(obj, Vg, t, Vds)
            obj.logger.debug('Simulating with %d time points', length(t));
            obj.checkStop();
            
            P0 = obj.parameters.P0;
            M0 = obj.parameters.M0;
            tau_de = obj.parameters.tau_de;
            f = obj.parameters.f;
            uc = obj.parameters.uc;
            L = obj.parameters.L;
            mu_p = obj.parameters.holes_mobility;
            q = obj.parameters.q;
            VT = obj.VT;
            
            t = t(:);
            Vg = Vg(:);
            n = length(t);
            
            if isscalar(Vds)
                Vds = Vds * ones(n, 1);
            else
                Vds = Vds(:);
            end
            
            Id = zeros(n, 1);
            M = zeros(n, 1);
            
            Meq_func = @(v) (2/3) * M0 * max((abs(v - uc)) / VT, 0)^(1.5);
            M(1) = Meq_func(Vg(1));
            
            for i = 1:n
                obj.checkStop();
                
                dt = 0;
                if i > 1
                    dt = t(i) - t(i-1);
                end
                
                v_mag = max(abs(Vds(i)), 1e-6);
                tau_e = (L^2) / (mu_p * v_mag);
                theta = sign(Vds(i));
                if theta == 0
                    theta = 1;
                end
                
                Meq_val = Meq_func(Vg(i));
                dMdt = (Meq_val - M(i)) / max(tau_de, 1e-9);
                
                if i < n
                    M(i+1) = M(i) + dMdt * dt;
                end
                
                eff_carriers = max(P0 - M(i), 0);
                term_steady = theta * (q * L / tau_e) * eff_carriers;
                term_transient = -q * f * L * dMdt;
                
                Id(i) = term_steady + term_transient;
            end
            
            sim.t = t;
            sim.Id = Id;
            sim.Vgs = Vg;
            sim.Vds = Vds;
            sim.M = M;
            
            obj.logger.debug('Simulation complete');
        end
        
        function fitResults = fit(obj, data)
            obj.logger.info('Starting Bisquert model fit');
            obj.logger.info('Data: %d transient files', length(data.transient.filenames));
            
            nFiles = length(data.transient.filenames);
            allResults = cell(nFiles, 1);
            
            if obj.canUseParallel()
                obj.logger.info('Using parallel processing');
                parfor i = 1:nFiles
                    allResults{i} = obj.fitSingleFile(data, i);
                end
            else
                obj.logger.info('Using serial processing');
                for i = 1:nFiles
                    obj.logger.debug('Fitting file %d/%d', i, nFiles);
                    allResults{i} = obj.fitSingleFile(data, i);
                    if obj.stopFlag
                        break;
                    end
                end
            end
            
            fitResults = obj.aggregateFits(allResults);
            obj.logger.info('Fit complete. R2 = %.4f', fitResults.avgR2);
        end
        
        function result = fitSingleFile(obj, data, idx)
            parsed = obj.getTransientRecord(data, idx);
            
            Vgs = parsed.filename_Vgs;
            if isnan(Vgs)
                Vgs = mean(parsed.Vgs);
            end
            Vds = parsed.filename_Vds;
            if isnan(Vds)
                Vds = mean(parsed.Vds);
            end
            
            uc_val = obj.getUc(Vgs, Vds, data);
            
            t = parsed.time;
            Id = parsed.drainCurrent;
            
            valid = (t > 0) & isfinite(t) & isfinite(Id);
            t_clean = t(valid);
            Id_clean = Id(valid);
            
            if numel(t_clean) < 50
                result = obj.createFailedResult('Not enough data points');
                return;
            end

            % FIX: ensure monotonic unique time for interp1
            [t_clean, sortIdx] = sort(t_clean(:), 'ascend');
            Id_clean = Id_clean(sortIdx);
            [t_unique, ia] = unique(t_clean, 'stable');
            Id_unique = Id_clean(ia);

            if numel(t_unique) < 50
                result = obj.createFailedResult('Not enough unique time points');
                return;
            end
            
            tmin = min(t_unique);
            tmax = max(t_unique);
            if ~(isfinite(tmin) && isfinite(tmax) && tmin > 0 && tmax > tmin)
                result = obj.createFailedResult('Invalid time window after cleaning');
                return;
            end

            t_fit = logspace(log10(tmin), log10(tmax), 250)';
            Id_fit = interp1(t_unique, Id_unique, t_fit, 'pchip', 'extrap');

            if any(~isfinite(Id_fit))
                result = obj.createFailedResult('Interpolation produced non-finite values');
                return;
            end
            
            try
                [p_opt, fit_info] = obj.stagedFit(t_fit, Id_fit, Vgs, Vds, uc_val);
                
                [fit_curve, ~] = obj.evaluateFit(p_opt, t_fit, Vgs, Vds, uc_val);
                metrics = obj.computeFitMetrics(Id_fit, fit_curve);
                
                result = struct();
                result.f = p_opt(1);
                result.tau_de = 10^p_opt(2);
                result.M0_fit = 10^p_opt(3);
                result.I_off = p_opt(4);
                result.R2 = metrics.R2;
                result.RMSE = metrics.RMSE;
                result.NRMSE = metrics.NRMSE;
                result.success = true;
                result.iterations = fit_info.iterations;
                result.funcCount = fit_info.funcCount;
                result.Vgs = Vgs;
                result.Vds = Vds;
                
            catch ME
                obj.logger.warn('Fit failed for file %d: %s', idx, ME.message);
                result = obj.createFailedResult(ME.message);
            end
        end
        function [p_opt, info] = stagedFit(obj, t, Id, Vgs, Vds, uc)
            P0 = obj.parameters.P0;
            L = obj.parameters.L;
            mu_p = obj.parameters.holes_mobility;
            VT = obj.VT;
            q = obj.parameters.q;
            
            lb1 = [-9, 0];
            ub1 = [5, 1];
            p01 = [-2, 0.5];
            
            obj_fun1 = @(p) obj.getResidual(p, t, Id, Vgs, Vds, uc, P0, L, mu_p, VT, q, true);
            [p1, ~] = obj.runGlobalSearch(obj_fun1, lb1, ub1, p01);
            
            lb2 = [10, p1(1), p1(2)];
            ub2 = [17, p1(1), p1(2)];
            p02 = [log10(P0), p1(1), p1(2)];
            
            obj_fun2 = @(p) obj.getResidual(p, t, Id, Vgs, Vds, uc, P0, L, mu_p, VT, q, false);
            [p2, info] = obj.runGlobalSearch(obj_fun2, lb2, ub2, p02);
            
            p_opt = [p2(3), p2(2), 10^p2(1), 0];
            
            lb3 = [0, p2(2)-0.5, 10^(p2(1)-0.5), -1e-4];
            ub3 = [1, p2(2)+0.5, 10^(p2(1)+0.5), 1e-4];
            p03 = p_opt;
            
            obj_fun3 = @(p) obj.getResidualFull(p, t, Id, Vgs, Vds, uc, P0, L, mu_p, VT, q);
            [p_opt, info] = obj.runLocalSearch(obj_fun3, lb3, ub3, p03);
        end
        
        function r = getResidual(obj, p, t, Id, Vgs, Vds, uc, P0, L, mu_p, VT, q, fixM0)
            if fixM0
                tau_d = 10^p(1);
                f = p(2);
                M0 = obj.parameters.M0;
                I_off = 0;
            else
                M0 = 10^p(1);
                tau_d = 10^p(2);
                f = p(3);
                I_off = 0;
            end
            
            [Id_fit, ~] = obj.computeFit([f, tau_d, M0, I_off], t, Vgs, Vds, uc, P0, L, mu_p, VT, q);
            r = (Id_fit - Id) ./ (abs(Id) + 1e-8);
        end
        
        function r = getResidualFull(obj, p, t, Id, Vgs, Vds, uc, P0, L, mu_p, VT, q)
            [Id_fit, ~] = obj.computeFit(p, t, Vgs, Vds, uc, P0, L, mu_p, VT, q);
            r = (Id_fit - Id) ./ (abs(Id) + 1e-8);
        end
        
        function [Id_fit, M] = computeFit(obj, p, t, Vgs, Vds, uc, P0, L, mu_p, VT, q)
            f = p(1);
            tau_d = p(2);
            M0 = p(3);
            I_off = p(4);
            
            n = length(t);
            Id_fit = zeros(n, 1);
            M = zeros(n, 1);
            
            v_mag = max(abs(Vds), 1e-6);
            tau_e = (L^2) / (mu_p * v_mag);
            theta = sign(Vds);
            if theta == 0, theta = 1; end
            
            Meq_func = @(v) (2/3) * M0 * (abs(v - uc)/VT)^(1.5);
            M(1) = Meq_func(0);
            
            for i = 1:n
                dt = 0;
                if i > 1
                    dt = t(i) - t(i-1);
                end
                
                Meq_val = Meq_func(Vgs);
                dMdt = (Meq_val - M(i)) / max(tau_d, 1e-12);
                
                if i < n
                    M(i+1) = M(i) + dMdt * dt;
                end
                
                I_drift = theta * (q * L / tau_e) * max(P0 - M(i), 0);
                I_disp = -q * L * f * dMdt;
                Id_fit(i) = I_drift + I_disp + I_off;
            end
        end
        
        function [p_opt, info] = runGlobalSearch(obj, objective, lb, ub, x0)
            options = optimoptions('fmincon', 'Display', 'off', 'Algorithm', 'sqp');
            problem = createOptimProblem('fmincon', ...
                'x0', x0, ...
                'objective', objective, ...
                'lb', lb, ...
                'ub', ub, ...
                'options', options);
            
            gs = GlobalSearch('Display', 'off', 'NumTrialPoints', 100);
            [p_opt, ~, exitflag, output] = run(gs, problem);
            
            info.exitflag = exitflag;
            info.iterations = output.iterations;
            info.funcCount = output.funcCount;
        end
        
        function [p_opt, info] = runLocalSearch(obj, objective, lb, ub, x0)
            options = optimoptions('fmincon', 'Display', 'off', 'Algorithm', 'sqp', ...
                'MaxIterations', 500, 'MaxFunctionEvaluations', 5000);
            
            [p_opt, ~, exitflag, output] = fmincon(objective, x0, [], [], [], [], lb, ub, [], options);
            
            info.exitflag = exitflag;
            info.iterations = output.iterations;
            info.funcCount = output.funcCount;
        end
        
        function [Id_fit, M] = evaluateFit(obj, p, t, Vgs, Vds, uc)
            P0 = obj.parameters.P0;
            L = obj.parameters.L;
            mu_p = obj.parameters.holes_mobility;
            VT = obj.VT;
            q = obj.parameters.q;
            
            [Id_fit, M] = obj.computeFit(p, t, Vgs, Vds, uc, P0, L, mu_p, VT, q);
        end
        
        function uc = getUc(obj, Vgs, Vds, data)
            uc = obj.parameters.uc;
            
            if isfield(data, 'steadyState') && isfield(data.steadyState, 'parsed')
                parsed = data.steadyState.parsed;
                [~, idx] = min(abs(parsed.Vd_sorted - Vds));
                Id_col = parsed.Id_matrix(:, idx);
                gm = gradient(Id_col, parsed.Vg_sorted);
                [~, max_idx] = max(abs(gm));
                uc = parsed.Vg_sorted(max_idx);
            end
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
        function parsed = getTransientRecord(obj, data, idx)
    tr = data.transient;

    if isfield(tr, 'parsed') && ~isempty(tr.parsed)
        parsed = tr.parsed{idx};
        return;
    end
    if isfield(tr, 'data') && ~isempty(tr.data)
        parsed = tr.data{idx};
        return;
    end
    if isfield(tr, 'files') && ~isempty(tr.files)
        parsed = tr.files{idx};
        return;
    end
    if iscell(tr)
        parsed = tr{idx};
        return;
    end

    error('OECT:TransientFormat', ...
        'Transient data format unsupported: expected transient.parsed/data/files cell array');
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
            
            f_vals = cellfun(@(r) r.f, allResults(good_idx));
            tau_vals = cellfun(@(r) r.tau_de, allResults(good_idx));
            M0_vals = cellfun(@(r) r.M0_fit, allResults(good_idx));
            R2_vals = cellfun(@(r) r.R2, allResults(good_idx));
            
            fitResults.avg_f = median(f_vals);
            fitResults.avg_tau_de = median(tau_vals);
            fitResults.avg_M0 = median(M0_vals);
            fitResults.avgR2 = median(R2_vals);
            fitResults.std_f = std(f_vals);
            fitResults.std_tau = std(tau_vals);
            fitResults.std_M0 = std(M0_vals);
            
            obj.parameters.params.f = fitResults.avg_f;
            obj.parameters.params.tau_de = fitResults.avg_tau_de;
            obj.parameters.params.M0 = fitResults.avg_M0;
            
            fitResults.parameters = obj.parameters;
            fitResults.all_results = allResults(good_idx);
            fitResults.good_idx = good_idx;
        end
    end
end