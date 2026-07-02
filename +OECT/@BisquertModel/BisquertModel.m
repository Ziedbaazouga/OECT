classdef BisquertModel < OECT.Model
    properties (Access = private)
        VT double
    end

    methods
        function obj = BisquertModel(parameters)
            if nargin < 1
                parameters = OECT.Parameters('Bisquert');
            end
            obj@OECT.Model(parameters);
            obj.modelName = 'Bisquert';
            obj.logger = OECT.Logger('BisquertModel');
            obj.VT = (obj.parameters.kB * obj.parameters.T) / obj.parameters.q;
        end

        function mu = getHolesMobility(obj)
            mu = obj.getParamOrDefault('holes_mobility', 2e-4);
            if ~isfinite(mu) || mu <= 0
                mu = 2e-4;
            end
        end

        function fitResults = fit(obj, data)
            obj.logger.info('Starting Bisquert fit (embedded old-old pipeline)');

            [steadyFile, steadySheets] = obj.extractSteadyInfo(data);
            [transientFiles, transientSheets, transientParsed] = obj.extractTransientInfo(data);

            nTr = numel(transientFiles);
            if nTr == 0
                error('No transient files found in loaded data.');
            end

            V_g = zeros(1, nTr);
            V_s = zeros(1, nTr);
            V_d = nan(1, nTr);
            v_g = nan(1, nTr);

            for k = 1:nTr
                rec = [];
                if ~isempty(transientParsed) && numel(transientParsed) >= k
                    rec = transientParsed{k};
                end
                if ~isempty(rec) && isstruct(rec)
                    if isfield(rec,'filename_Vds') && isfinite(rec.filename_Vds)
                        V_d(k) = rec.filename_Vds;
                    end
                    if isfield(rec,'filename_Vgs') && isfinite(rec.filename_Vgs)
                        v_g(k) = rec.filename_Vgs;
                    end
                end
            end

            for k = 1:nTr
                if ~isfinite(V_d(k)) || ~isfinite(v_g(k))
                    [vd_, vg_] = obj.parseBiasFromFilename(transientFiles{k});
                    if ~isfinite(V_d(k)), V_d(k) = vd_; end
                    if ~isfinite(v_g(k)), v_g(k) = vg_; end
                end
            end

            V_d(~isfinite(V_d)) = -0.1;
            v_g(~isfinite(v_g)) = 0;

            d  = obj.getParamOrDefault('d', 10e-6); %#ok<NASGU>
            L  = obj.getParamOrDefault('L', 25e-6);
            W  = obj.getParamOrDefault('W', 10e-6); %#ok<NASGU>
            T  = obj.getParamOrDefault('T', 290);
            mu = obj.getHolesMobility();

            [boltzmann, q, uc_interp, P0, M0_scale, M0_avg, f_interp, tau_de_avg, run_results] = ...
                obj.getModelParametersEmbedded( ...
                    V_g, V_d, V_s, v_g, d, L, W, T, mu, ...
                    steadyFile, steadySheets, transientFiles, transientSheets);

            if isfinite(P0) && P0 > 0,                 obj.parameters.setParameter('P0', P0); end
            if isfinite(M0_avg) && M0_avg > 0,         obj.parameters.setParameter('M0', M0_avg); end
            if isfinite(tau_de_avg) && tau_de_avg > 0, obj.parameters.setParameter('tau_de', tau_de_avg); end

            f0  = obj.safeInterpEval(f_interp, 0, -0.2, obj.getParamOrDefault('f', 0.5));
            uc0 = obj.safeInterpEval(uc_interp, 0, -0.2, obj.getParamOrDefault('uc', 0.05));
            if isfinite(f0),  obj.parameters.setParameter('f', f0); end
            if isfinite(uc0), obj.parameters.setParameter('uc', uc0); end

            valid_fit_mask = isfinite(run_results.R2) & (run_results.R2 > 0);
            n_success = sum(valid_fit_mask);
            avgR2 = mean(run_results.R2(valid_fit_mask), 'omitnan');

            fitResults = struct();
            fitResults.success = n_success > 0;
            fitResults.n_total = nTr;
            fitResults.n_success = n_success;
            fitResults.n_failed = nTr - n_success;
            fitResults.avgR2 = avgR2;

            fitResults.avg_f = mean(run_results.f(valid_fit_mask), 'omitnan');
            fitResults.avg_tau_de = tau_de_avg;
            fitResults.avg_M0 = M0_avg;

            fitResults.P0 = P0;
            fitResults.M0_scale = M0_scale;
            fitResults.uc_interp = uc_interp;
            fitResults.f_interp = f_interp;
            fitResults.kB = boltzmann;
            fitResults.q = q;
            fitResults.V_d = V_d;
            fitResults.v_g = v_g;
            fitResults.run_results = run_results;
            fitResults.parameters = obj.parameters;

            obj.logger.info('Bisquert fit done: n_success=%d/%d, avgR2=%.4f', n_success, nTr, avgR2);

            if ~fitResults.success
                error('No valid fits found (R2 > 0).');
            end
        end

        function sim = simulate(obj, Vg, t, Vds)
            t = t(:);
            ug = Vg(:);
            n = numel(t);

            if isscalar(Vds)
                uds = Vds * ones(n,1);
            else
                uds = Vds(:);
                if numel(uds) ~= n
                    error('Vds must be scalar or same length as t');
                end
            end

            q = obj.getParamOrDefault('q', 1.602176634e-19);
            kB = obj.getParamOrDefault('kB', 1.380649e-23);
            T = obj.getParamOrDefault('T', 290);

            L = obj.getParamOrDefault('L', 25e-6);
            mu_p = obj.getHolesMobility();

            P0 = obj.getParamOrDefault('P0', 1e26);
            M0 = obj.getParamOrDefault('M0', 5e25);
            tau_d = obj.getParamOrDefault('tau_de', 1e-2);
            f = obj.getParamOrDefault('f', 0.5);
            uc = obj.getParamOrDefault('uc', 0.05);

            Id = obj.localBisquetModelParam([f, log10(max(tau_d,1e-12)), log10(max(M0,1e10)), 0], ...
                L, mu_p, median(uds,'omitnan'), uc, P0, kB, T, q, median(ug,'omitnan'), t, ug(1));

            sim = struct('t',t,'Id',Id,'Vgs',ug,'Vds',uds);
        end

        function [Vg, Id, gm] = transferCharacteristics(obj, Vg_range, Vds_fixed)
            if nargin < 2 || isempty(Vg_range), Vg_range = linspace(-0.6,0.6,80); end
            if nargin < 3 || isempty(Vds_fixed), Vds_fixed = -0.1; end
            t = linspace(0, max(1e-3,10*max(obj.getParamOrDefault('tau_de',1e-2),1e-6)), 220).';
            Id = zeros(size(Vg_range));
            for k = 1:numel(Vg_range)
                s = obj.simulate(Vg_range(k)*ones(size(t)), t, Vds_fixed);
                Id(k) = s.Id(end);
            end
            Vg = Vg_range;
            gm = gradient(Id, Vg);
        end

        function [Vd, Id] = outputCharacteristics(obj, Vg_fixed, Vd_range)
            if nargin < 2 || isempty(Vg_fixed), Vg_fixed = -0.2; end
            if nargin < 3 || isempty(Vd_range), Vd_range = linspace(-0.6,0.0,60); end
            t = linspace(0, max(1e-3,10*max(obj.getParamOrDefault('tau_de',1e-2),1e-6)), 220).';
            vg = Vg_fixed * ones(size(t));
            Id = zeros(size(Vd_range));
            for k = 1:numel(Vd_range)
                s = obj.simulate(vg, t, Vd_range(k));
                Id(k) = s.Id(end);
            end
            Vd = Vd_range;
        end

        function name = getModelName(~), name = 'Bisquert'; end
        function desc = getModelDescription(~), desc = 'Bisquert model (embedded old-old fitting pipeline)'; end
        function params = getParameterNames(~), params = {'P0','M0','tau_de','f','uc','holes_mobility'}; end
        function bounds = getParameterBounds(~)
            bounds = struct('P0',[1e20,1e30],'M0',[1e10,1e30],'tau_de',[1e-9,1e5],'f',[0,1],'uc',[-5,5],'holes_mobility',[1e-8,1]);
        end
    end

    methods (Access = private)
        function [boltzmann, q, uc_interp, P0, M0_scale, M0_avg, f_interp, tau_de_avg, run_results] = ...
                getModelParametersEmbedded(obj, V_g, V_d, V_s, v_g, d, L, W, T, holes_mobility, file_name_steadystate, sheetnames_steadystate, file_name_transient, sheetnames_transient) %#ok<INUSD>

            q = 1.602176634e-19;
            boltzmann = 1.380649e-23;

            [Vg_ss_sorted, Vd_ss_sorted, uc_ss_matrix, P0, M0_scale] = obj.getSteadyStateConstantsEmbedded( ...
                file_name_steadystate, sheetnames_steadystate, boltzmann, q, T, holes_mobility, L);

            % fallback instead of hard fail
            if ~isfinite(P0) || P0 <= 0
                P0 = obj.getParamOrDefault('P0', 1e26);
                obj.logger.warning('Steady-state P0 invalid; using fallback P0=%.3e', P0);
            end
            if ~isfinite(M0_scale) || M0_scale <= 0
                M0_scale = obj.getParamOrDefault('M0', 5e25);
                obj.logger.warning('Steady-state M0_scale invalid; using fallback M0=%.3e', M0_scale);
            end

            v_gs_unique = sort(unique(v_g(:).'), 'ascend');
            V_ds_unique = sort(unique(V_d(:).'), 'ascend');
            uc_interp = griddedInterpolant({Vg_ss_sorted, Vd_ss_sorted}, uc_ss_matrix, 'linear', 'nearest');

            nRuns = numel(file_name_transient);
            f_matrix = nan(numel(v_gs_unique), numel(V_ds_unique));

            run_results = table('Size', [nRuns, 10], ...
                'VariableTypes', {'string','double','double','double','double','double','double','double','double','double'}, ...
                'VariableNames', {'File','Vgs_V','Vds_V','uc_V','f','tau_de_s','M0_fit','R2','RMSE','NRMSE'});

            doPlotFits = false;
            fitWindow = struct('t_min', 1e-3, 't_max_frac', 0.90); %#ok<NASGU>

            for k = 1:nRuns
                thisFile = file_name_transient{k};
                thisVgs  = v_g(k);
                thisVds  = V_d(k);

                uc_val = uc_interp(thisVgs, thisVds);

                params = obj.getTransientParametersEmbedded( ...
                    boltzmann, T, thisFile, sheetnames_transient, thisVgs, thisVds, uc_val, P0, L, holes_mobility, doPlotFits, fitWindow);

                run_results.File(k) = string(thisFile);
                run_results.Vgs_V(k) = thisVgs;
                run_results.Vds_V(k) = thisVds;
                run_results.uc_V(k) = uc_val;
                run_results.f(k) = params.f;
                run_results.tau_de_s(k) = params.tau_d;
                run_results.M0_fit(k) = params.M0;
                run_results.R2(k) = params.R2;
                run_results.RMSE(k) = params.RMSE;
                run_results.NRMSE(k) = params.NRMSE;

                ig = find(v_gs_unique == thisVgs, 1);
                idd = find(V_ds_unique == thisVds, 1);
                if ~isempty(ig) && ~isempty(idd), f_matrix(ig, idd) = params.f; end
            end

            valid_fit_mask = run_results.R2 > 0;
            if ~any(valid_fit_mask)
                error('No valid fits found. Cannot calculate average parameters.');
            end

            tau_de_avg = mean(run_results.tau_de_s(valid_fit_mask), 'omitnan');
            M0_avg = mean(run_results.M0_fit(valid_fit_mask), 'omitnan');
            if ~isfinite(M0_avg) || M0_avg <= 0
                M0_avg = M0_scale;
            end

            f_interp = griddedInterpolant({v_gs_unique, V_ds_unique}, f_matrix, 'linear', 'nearest');
        end

        function [Vg_sorted, Vd_sorted, uc_matrix, P0, M0] = getSteadyStateConstantsEmbedded(obj, file_name_steadystate, sheetnames_steadystate, boltzmann, q, T, holes_mobility, L)

            nSheets = length(sheetnames_steadystate);

            % first sheet to size blocks
            tbl0 = readtable(file_name_steadystate, 'Sheet', sheetnames_steadystate{1}, 'VariableNamingRule','preserve');
            d0 = obj.tableToNumeric(tbl0);

            % drop header/empty rows that become all-NaN
            keep0 = any(isfinite(d0), 2);
            d0 = d0(keep0, :);

            [nr0,nc0] = size(d0);
            nVd = min(9, floor((nc0 - 2)/5) + 1);
            nVg = min(17, nr0);

            if nVg < 5 || nVd < 3
                error('Steady-state sheet format unsupported after header cleanup.');
            end

            gate_Voltage = nan(nVg, 1, nSheets);
            drain_Voltage = nan(1, nVd, nSheets);
            Id_meas_all = nan(nVg, nVd, nSheets);

            for s = 1:nSheets
                tbl = readtable(file_name_steadystate, 'Sheet', sheetnames_steadystate{s}, 'VariableNamingRule','preserve');
                data = obj.tableToNumeric(tbl);

                keep = any(isfinite(data), 2);
                data = data(keep, :);

                [nr,nc] = size(data);
                nVg_s = min(nVg, nr);
                nVd_s = min(nVd, floor((nc - 2)/5) + 1);

                for i = 0:(nVd_s-1)
                    cI  = 1 + 5*i; % DrainI(i)
                    cVd = 2 + 5*i; % DrainV(i)
                    cVg = 4 + 5*i; % GateV(i)

                    if cI <= nc
                        Id_meas_all(1:nVg_s, i+1, s) = data(1:nVg_s, cI);
                    end
                    if cVd <= nc
                        drain_Voltage(1, i+1, s) = data(1, cVd);
                    end
                    if cVg <= nc
                        gate_Voltage(1:nVg_s, 1, s) = data(1:nVg_s, cVg);
                    end
                end
            end

            Vg_raw = mean(gate_Voltage, 3, 'omitnan');
            Vd_raw = mean(drain_Voltage, 3, 'omitnan');
            Id_raw = mean(Id_meas_all, 3, 'omitnan');

            [Vg_sorted, idxVg] = sort(Vg_raw(:), 'ascend');
            [Vd_sorted, idxVd] = sort(Vd_raw(:).', 'ascend');
            Id = Id_raw(idxVg, idxVd);

            nVdEff = numel(Vd_sorted);
            uc_vec = nan(1, nVdEff);
            gm_max_each = nan(1, nVdEff);

            for j = 1:nVdEff
                y = smoothdata(abs(Id(:,j)), 'movmedian', 3);
                if all(~isfinite(y)) || max(y) < 1e-12, continue; end
                gm = abs(gradient(y, Vg_sorted));
                [gm_max, idx_max_gm] = max(gm);
                if ~isempty(idx_max_gm)
                    uc_vec(j) = Vg_sorted(idx_max_gm);
                    gm_max_each(j) = gm_max;
                end
            end

            uc_matrix = repmat(uc_vec, numel(Vg_sorted), 1);

            avg_uc = mean(uc_vec, 'omitnan');
            if ~isfinite(avg_uc), avg_uc = 0; end

            on_region_mask = Vg_sorted < (avg_uc - 0.2);
            if ~any(on_region_mask), on_region_mask = Vg_sorted < -0.2; end

            Id_plateau = nan(1, nVdEff);
            for j = 1:nVdEff
                Id_plateau(j) = median(Id(on_region_mask, j), 'omitnan');
            end

            P0_each = abs(L .* Id_plateau ./ (Vd_sorted .* q .* holes_mobility));
            valid_P0_mask = (abs(Vd_sorted) > 1e-6) & isfinite(P0_each);
            P0 = mean(P0_each(valid_P0_mask), 'omitnan');

            VT = (boltzmann * T) / q;
            gm_max_avg = mean(gm_max_each, 'omitnan');
            if ~isfinite(gm_max_avg) || gm_max_avg <= 1e-9
                M0 = NaN;
            else
                M0 = ((gm_max_avg * 3 * sqrt(VT)) / (2 * q * holes_mobility))^(2/3);
            end
        end

        function params = getTransientParametersEmbedded(obj, kB, T, file_name_transient, sheetnames_transient, v_gs, V_ds, v_c, P0, L, mu_p, doPlot, fitWindow) %#ok<INUSD>
            if nargin < 12 || isempty(doPlot), doPlot = false; end
            q = 1.602176634e-19;

            lb = [0, -9, 10, -1e-4];
            ub = [1,  5, 17,  1e-4];
            p0 = [0.5, -2, log10(max(P0,1e10)), 0];

            localOptions = optimoptions('fmincon', 'Display', 'off', 'Algorithm', 'sqp');
            nSheets = length(sheetnames_transient);
            results = struct('f',[],'tau_d',[],'M0',[],'I_off',[],'R2',[],'RMSE',[],'NRMSE',[]);

            for j = 1:nSheets
                sheetname = sheetnames_transient{j};
                tbl = readtable(file_name_transient, 'Sheet', sheetname, 'VariableNamingRule', 'preserve');
                data = obj.tableToNumeric(tbl);
                [nr,nc] = size(data);

                if nr < 70 || nc < 3, continue; end

                r1 = min(68, nr);
                r2 = min(2030, nr);
                if r2 <= r1, continue; end

                if nc >= 4
                    Vgs_initial = data(1,4);
                else
                    Vgs_initial = v_gs;
                end

                t_raw  = data(r1:r2,1) - data(r1,1);
                Id_raw = data(r1:r2,3);

                valid = isfinite(Id_raw) & isfinite(t_raw) & (t_raw > 0);
                t_clean = t_raw(valid);
                Id_clean = Id_raw(valid);
                if numel(t_clean) < 50, continue; end

                t_fit = logspace(log10(min(t_clean)), log10(max(t_clean)), 250)';
                Id_fit = interp1(t_clean, Id_clean, t_fit, 'pchip');

                weights = 1 ./ ((t_fit + 1e-4).^0.05);
                tail_start_idx = round(0.9 * length(t_fit));
                weights(tail_start_idx:end) = weights(tail_start_idx:end) * 10;
                weights = weights / mean(weights);

                objective_fun = @(p) sum(weights .* ...
                    ((obj.localBisquetModelParam(p, L, mu_p, V_ds, v_c, P0, kB, T, q, v_gs, t_fit, Vgs_initial) - Id_fit) ...
                    ./ (abs(Id_fit) + 1e-8)).^2);

                p_warm = fmincon(objective_fun, p0, [], [], [], [], lb, ub, [], localOptions);
                problem = createOptimProblem('fmincon', 'x0', p_warm, 'objective', objective_fun, 'lb', lb, 'ub', ub, 'options', localOptions);
                gs = GlobalSearch('Display', 'off');
                p_opt = run(gs, problem);

                f_val = p_opt(1);
                tau_d_val = 10^p_opt(2);
                M0_val = 10^p_opt(3);
                I_off_val = p_opt(4);

                fit_curve = obj.localBisquetModelParam(p_opt, L, mu_p, V_ds, v_c, P0, kB, T, q, v_gs, t_fit, Vgs_initial);
                res = fit_curve - Id_fit;

                results.f(j) = f_val;
                results.tau_d(j) = tau_d_val;
                results.M0(j) = M0_val;
                results.I_off(j) = I_off_val;
                results.R2(j) = 1 - sum(res.^2) / (sum((Id_fit - mean(Id_fit)).^2) + eps);
                results.RMSE(j) = sqrt(mean(res.^2));
                results.NRMSE(j) = results.RMSE(j) / (max(Id_fit) - min(Id_fit) + eps);
            end

            params.f = mean(results.f, 'omitnan');
            params.tau_d = mean(results.tau_d, 'omitnan');
            params.M0 = mean(results.M0, 'omitnan');
            params.I_off = mean(results.I_off, 'omitnan');
            params.R2 = mean(results.R2, 'omitnan');
            params.RMSE = mean(results.RMSE, 'omitnan');
            params.NRMSE = mean(results.NRMSE, 'omitnan');
        end

        function Id = localBisquetModelParam(~, p, L, mu_p, uds, uc, P0, kB, T, q, ug, time, Vgs_initial)
            f = p(1);
            tau_d = 10^p(2);
            M0 = 10^p(3);
            I_offset = p(4);

            n = length(time);
            Id = zeros(n,1); M = zeros(n,1);

            VT = (kB*T)/q;
            v_mag = max(abs(uds), 1e-6);
            tau_e = (L^2)/(mu_p*v_mag);
            theta = sign(uds);

            Meq_func = @(v) (2/3)*M0*(abs(v-uc)/VT)^(1.5);
            M(1) = Meq_func(Vgs_initial);

            for i = 1:n
                dt = 0; if i > 1, dt = time(i)-time(i-1); end
                Meq_val = Meq_func(ug);
                dMdt = (Meq_val - M(i))/max(tau_d,1e-12);
                if i < n, M(i+1) = M(i) + dMdt*dt; end
                I_drift = theta*(q*L/tau_e)*max(P0 - M(i), 0);
                I_disp  = -q*L*f*dMdt;
                Id(i) = I_drift + I_disp + I_offset;
            end
        end

        function A = tableToNumeric(~, tbl)
            nR = height(tbl);
            nC = width(tbl);
            A = nan(nR, nC);

            for c = 1:nC
                col = tbl.(c);

                if isnumeric(col)
                    A(:,c) = double(col);

                elseif islogical(col)
                    A(:,c) = double(col);

                elseif isstring(col)
                    A(:,c) = str2double(col);

                elseif iscell(col)
                    tmp = nan(nR,1);
                    for r = 1:nR
                        v = col{r};
                        if isnumeric(v) && isscalar(v)
                            tmp(r) = double(v);
                        elseif islogical(v) && isscalar(v)
                            tmp(r) = double(v);
                        else
                            tmp(r) = str2double(string(v));
                        end
                    end
                    A(:,c) = tmp;

                else
                    A(:,c) = str2double(string(col));
                end
            end
        end

        function [steadyFile, steadySheets] = extractSteadyInfo(~, data)
            ss = [];
            if isstruct(data)
                if isfield(data,'steadyState') && ~isempty(data.steadyState), ss = data.steadyState;
                elseif isfield(data,'steady') && ~isempty(data.steady), ss = data.steady;
                elseif isfield(data,'data') && isstruct(data.data)
                    if isfield(data.data,'steadyState') && ~isempty(data.data.steadyState), ss = data.data.steadyState;
                    elseif isfield(data.data,'steady') && ~isempty(data.data.steady), ss = data.data.steady;
                    end
                end
            elseif isobject(data) && isprop(data,'steadyState')
                ss = data.steadyState;
            end
            if isempty(ss), error('steadyState data missing.'); end

            if isfield(ss,'filePath') && ~isempty(ss.filePath), steadyFile = ss.filePath;
            elseif isfield(ss,'filename') && ~isempty(ss.filename), steadyFile = ss.filename;
            elseif isfield(ss,'file') && ~isempty(ss.file), steadyFile = ss.file;
            else, error('steady-state file path missing.'); end

            if isfield(ss,'sheetNames') && ~isempty(ss.sheetNames), steadySheets = ss.sheetNames;
            elseif isfield(ss,'sheets') && ~isempty(ss.sheets), steadySheets = ss.sheets;
            else, [~, steadySheets] = xlsfinfo(steadyFile);
            end

            if ischar(steadySheets), steadySheets = {steadySheets}; end
            if isstring(steadySheets), steadySheets = cellstr(steadySheets); end
        end

        function [transientFiles, transientSheets, transientParsed] = extractTransientInfo(~, data)
            tr = []; transientParsed = {};
            if isstruct(data)
                if isfield(data,'transient') && ~isempty(data.transient), tr = data.transient;
                elseif isfield(data,'data') && isstruct(data.data) && isfield(data.data,'transient') && ~isempty(data.data.transient), tr = data.data.transient;
                end
            elseif isobject(data) && isprop(data,'transient')
                tr = data.transient;
            end
            if isempty(tr), error('transient data missing.'); end

            if isfield(tr,'filePaths') && ~isempty(tr.filePaths), transientFiles = tr.filePaths;
            elseif isfield(tr,'filenames') && ~isempty(tr.filenames), transientFiles = tr.filenames;
            elseif isfield(tr,'files') && ~isempty(tr.files), transientFiles = tr.files;
            else, error('transient file list missing.'); end

            if ischar(transientFiles), transientFiles = {transientFiles}; end
            if isstring(transientFiles), transientFiles = cellstr(transientFiles); end

            if isfield(tr,'sheetNames') && ~isempty(tr.sheetNames), transientSheets = tr.sheetNames;
            elseif isfield(tr,'sheets') && ~isempty(tr.sheets), transientSheets = tr.sheets;
            else, transientSheets = {'Run1','Run2'};
            end
            if ischar(transientSheets), transientSheets = {transientSheets}; end
            if isstring(transientSheets), transientSheets = cellstr(transientSheets); end

            if isfield(tr,'parsed') && ~isempty(tr.parsed), transientParsed = tr.parsed; end
        end

        function [Vds, Vgs] = parseBiasFromFilename(~, filePath)
            [~, nm, ~] = fileparts(filePath);
            s = lower(strtrim(nm));
            tok = regexp(s, '([+-]?\d*\.?\d+)\s*vd.*?([+-]?\d*\.?\d+)\s*vg', 'tokens', 'once');
            if isempty(tok), Vds = NaN; Vgs = NaN; return; end
            Vds = str2double(tok{1}); Vgs = str2double(tok{2});
            if ~contains(tok{1}, '.') && abs(Vds) >= 2, Vds = Vds/10; end
            if ~contains(tok{2}, '.') && abs(Vgs) >= 2, Vgs = Vgs/10; end
        end

        function val = safeInterpEval(~, F, vg, vd, fallback)
            val = fallback;
            try
                if isa(F, 'griddedInterpolant'), tmp = F(vg,vd);
                elseif isa(F, 'function_handle'), tmp = F(vg,vd);
                else, tmp = fallback;
                end
                if isfinite(tmp), val = tmp; end
            catch
                val = fallback;
            end
        end

        function v = getParamOrDefault(obj, name, defaultVal)
            v = defaultVal;
            try
                if ismethod(obj.parameters, 'getParameter')
                    tmp = obj.parameters.getParameter(name);
                    if isfinite(tmp), v = tmp; return; end
                end
            catch
            end
            try
                if isprop(obj.parameters, name)
                    tmp = obj.parameters.(name);
                    if isfinite(tmp), v = tmp; return; end
                end
            catch
            end
            try
                if isprop(obj.parameters,'params') && isfield(obj.parameters.params,name)
                    tmp = obj.parameters.params.(name);
                    if isfinite(tmp), v = tmp; return; end
                end
            catch
            end
            try
                if isprop(obj.parameters,'geometry') && isfield(obj.parameters.geometry,name)
                    tmp = obj.parameters.geometry.(name);
                    if isfinite(tmp), v = tmp; return; end
                end
            catch
            end
            try
                if isprop(obj.parameters,'constants') && isfield(obj.parameters.constants,name)
                    tmp = obj.parameters.constants.(name);
                    if isfinite(tmp), v = tmp; return; end
                end
            catch
            end
        end
    end
end