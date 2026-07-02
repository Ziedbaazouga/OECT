classdef TestSuite < handle
    %OECT.TESTSUITE Test suite runner
    
    properties (Access = private)
        model OECT.Model
        logger OECT.Logger
        config struct
        results cell
        isRunning logical = false
        stopFlag logical = false
    end
    
    methods
        function obj = TestSuite(model, config)
            obj.model = model;
            obj.logger = OECT.Logger('TestSuite');
            obj.config = obj.setupConfig(config);
            obj.results = {};
        end
        
        function config = setupConfig(obj, userConfig)
            % Default configuration
            config = struct();
            config.Vds_fixed = -0.1;
            config.t_max = 0.05;
            config.n_pulses = 30;
            config.pulse_width_tau = 2;
            config.gap_tau = 1;
            config.save_data = false;
            config.Vg_range = [-0.6, 0.6];
            config.Vg_points = 50;
            config.Vd_range = [-0.6, 0.6];
            config.Vd_points = 40;
            config.Vg_levels = [-0.2, 0, 0.2];
            config.Vd_levels = [-0.4, -0.2, 0.2, 0.4];
            
            % Override with user config
            if nargin > 1 && ~isempty(userConfig)
                fields = fieldnames(userConfig);
                for i = 1:length(fields)
                    if isfield(config, fields{i})
                        config.(fields{i}) = userConfig.(fields{i});
                    end
                end
            end
        end
        
        function results = runAll(obj)
            % Run all tests
            obj.logger.info('Running all tests');
            testNames = obj.getTestNames();
            results = obj.runTests(testNames);
        end
        
        function results = runSelected(obj, testNames)
            % Run selected tests
            if ischar(testNames)
                testNames = {testNames};
            end
            obj.logger.info('Running %d tests', length(testNames));
            results = obj.runTests(testNames);
        end
        
        function results = runTests(obj, testNames)
            % Run tests with progress tracking
            obj.isRunning = true;
            obj.stopFlag = false;
            obj.results = {};
            
            nTests = length(testNames);
            
            for i = 1:nTests
                if obj.stopFlag
                    obj.logger.warn('Test suite stopped by user');
                    break;
                end
                
                obj.logger.info('Running test %d/%d: %s', i, nTests, testNames{i});
                
                try
                    result = obj.runSingleTest(testNames{i});
                    if ~isempty(result)
                        obj.results{end+1} = result;
                    end
                catch ME
                    obj.logger.error('Test %s failed: %s', testNames{i}, ME.message);
                end
            end
            
            obj.isRunning = false;
            results = obj.results;
        end
        
        function result = runSingleTest(obj, testName)
            % Run a single test
            
            result = OECT.TestResult(testName, testName);
            
            % Add common parameters
            result.setParameter('Vds_fixed', obj.config.Vds_fixed);
            result.setParameter('t_max', obj.config.t_max);
            result.setParameter('model', obj.model.getModelName());
            
            % Get tau
            tau = obj.getTau();
            
            switch testName
                case 'Step'
                    result = obj.runStep(result, tau);
                case 'Transfer'
                    result = obj.runTransfer(result);
                case 'Output'
                    result = obj.runOutput(result);
                case 'Hysteresis'
                    result = obj.runHysteresis(result);
                case 'PPX'
                    result = obj.runPPX(result, tau);
                case 'Vg Train (Amp)'
                    result = obj.runVgTrainAmp(result, tau);
                case 'Vg Train (Interval)'
                    result = obj.runVgTrainInterval(result, tau);
                case 'Vd Train (Amp)'
                    result = obj.runVdTrainAmp(result, tau);
                case 'Vd Train (Interval)'
                    result = obj.runVdTrainInterval(result, tau);
                case 'Vds Pulse'
                    result = obj.runVdsPulse(result, tau);
                otherwise
                    obj.logger.warn('Unknown test: %s', testName);
                    result = [];
            end
            
            if ~isempty(result)
                result.computeSummary();
                result.metadata.modelName = obj.model.getModelName();
                result.metadata.version = '2.0.0';
                if obj.config.save_data
                    result.save();
                end
            end
            
            obj.model.resetStopFlag();
        end
        
        function result = runStep(obj, result, tau)
            k_settle = 5;
            t_total = 2 * k_settle * tau;
            t_step_time = k_settle * tau;
            t = linspace(0, t_total, 10000);
            
            Vg = -0.2 * ones(size(t));
            Vg(t > t_step_time) = 0.2;
            
            sim = obj.model.simulate(Vg, t, obj.config.Vds_fixed);
            
            result.setData('t', sim.t);
            result.setData('Id', sim.Id);
            result.setData('Vg', Vg);
            result.setData('Vds', obj.config.Vds_fixed * ones(size(sim.t)));
            result.setParameter('tau', tau);
        end
        
        function result = runTransfer(obj, result)
            Vg_range = linspace(obj.config.Vg_range(1), obj.config.Vg_range(2), obj.config.Vg_points);
            
            if isa(obj.model, 'OECT.ShirinskayaModel')
                % Use steady-state calculation
                d = obj.model.parameters.d;
                L = obj.model.parameters.L;
                W = obj.model.parameters.W;
                sigma_inter = obj.model.sigma_inter;
                
                Id = zeros(length(Vg_range), length(obj.config.Vd_levels));
                
                for j = 1:length(obj.config.Vd_levels)
                    vds = obj.config.Vd_levels(j);
                    for i = 1:length(Vg_range)
                        if abs(vds) > 1e-10
                            Id(i, j) = -W * d * (1/L) * ...
                                integral(sigma_inter, Vg_range(i), Vg_range(i) - vds);
                        end
                    end
                end
            else
                % Use transient simulation
                t_settle = linspace(0, 5 * obj.getTau(), 500);
                Id = zeros(length(Vg_range), length(obj.config.Vd_levels));
                
                for j = 1:length(obj.config.Vd_levels)
                    vds = obj.config.Vd_levels(j);
                    for i = 1:length(Vg_range)
                        Vg_const = Vg_range(i) * ones(size(t_settle));
                        sim = obj.model.simulate(Vg_const, t_settle, vds);
                        Id(i, j) = sim.Id(end);
                    end
                end
            end
            
            result.setData('Vgs', Vg_range);
            result.setData('Vds', obj.config.Vd_levels);
            result.setData('Id', Id);
        end
        
        function result = runOutput(obj, result)
            Vd_range = linspace(obj.config.Vd_range(1), obj.config.Vd_range(2), obj.config.Vd_points);
            
            if isa(obj.model, 'OECT.ShirinskayaModel')
                d = obj.model.parameters.d;
                L = obj.model.parameters.L;
                W = obj.model.parameters.W;
                sigma_inter = obj.model.sigma_inter;
                
                Id = zeros(length(Vd_range), length(obj.config.Vg_levels));
                
                for j = 1:length(obj.config.Vg_levels)
                    vg = obj.config.Vg_levels(j);
                    for i = 1:length(Vd_range)
                        vd = Vd_range(i);
                        if abs(vd) > 1e-10
                            Id(i, j) = -W * d * (1/L) * ...
                                integral(sigma_inter, vg, vg - vd);
                        end
                    end
                end
            else
                t_settle = linspace(0, 5 * obj.getTau(), 500);
                Id = zeros(length(Vd_range), length(obj.config.Vg_levels));
                
                for j = 1:length(obj.config.Vg_levels)
                    vg = obj.config.Vg_levels(j);
                    Vg_const = vg * ones(size(t_settle));
                    for i = 1:length(Vd_range)
                        vd = Vd_range(i);
                        sim = obj.model.simulate(Vg_const, t_settle, vd);
                        Id(i, j) = sim.Id(end);
                    end
                end
            end
            
            result.setData('Vds', Vd_range);
            result.setData('Vg', obj.config.Vg_levels);
            result.setData('Id', Id);
        end
        
        function result = runHysteresis(obj, result)
            Vg_min = -0.4;
            Vg_max = 1.6;
            sweep_rate = 50;
            duration = (Vg_max - Vg_min) / sweep_rate;
            t = linspace(0, 2 * duration, 4001);
            
            Vg = Vg_min + (Vg_max - Vg_min) * sawtooth(2*pi*(1/(2*duration))*t, 0.5);
            
            Id_forward = cell(length(obj.config.Vd_levels), 1);
            Id_reverse = cell(length(obj.config.Vd_levels), 1);
            Vg_forward = cell(length(obj.config.Vd_levels), 1);
            Vg_reverse = cell(length(obj.config.Vd_levels), 1);
            
            for j = 1:length(obj.config.Vd_levels)
                vds = obj.config.Vd_levels(j);
                sim = obj.model.simulate(Vg, t, vds);
                
                half = floor(length(sim.t)/2);
                Vg_forward{j} = sim.Vgs(1:half);
                Vg_reverse{j} = sim.Vgs(half+1:end);
                Id_forward{j} = sim.Id(1:half);
                Id_reverse{j} = sim.Id(half+1:end);
            end
            
            result.setData('Vds', obj.config.Vd_levels);
            result.setData('Vg_forward', Vg_forward);
            result.setData('Vg_reverse', Vg_reverse);
            result.setData('Id_forward', Id_forward);
            result.setData('Id_reverse', Id_reverse);
        end
        
        function result = runPPX(obj, result, tau)
            Vg_base = 0;
            Vg_pulse = -0.4;
            Vds = -0.2;
            t_pulse_w = 3 * tau;
            settle_before = 5 * tau;
            
            dt_vals = linspace(0.1 * tau, 10 * tau, 15);
            PPX = zeros(size(dt_vals));
            raw_data = cell(length(dt_vals), 1);
            
            for di = 1:length(dt_vals)
                dt_gap = dt_vals(di);
                t_total = settle_before + t_pulse_w + dt_gap + t_pulse_w + settle_before;
                nPts = max(20000, round(t_total / (tau / 50)));
                t = linspace(0, t_total, nPts);
                
                Vg = Vg_base * ones(size(t));
                p1_start = settle_before;
                p1_end = settle_before + t_pulse_w;
                p2_start = p1_end + dt_gap;
                p2_end = p2_start + t_pulse_w;
                
                Vg(t >= p1_start & t < p1_end) = Vg_pulse;
                Vg(t >= p2_start & t < p2_end) = Vg_pulse;
                
                sim = obj.model.simulate(Vg, t, Vds);
                
                I_base = mean(sim.Id(sim.t < p1_start * 0.9));
                
                mask_p1 = sim.t >= p1_start & sim.t <= p1_end;
                A1 = max(abs(sim.Id(mask_p1) - I_base));
                
                mask_p2 = sim.t >= p2_start & sim.t <= p2_end;
                A2 = max(abs(sim.Id(mask_p2) - I_base));
                
                PPX(di) = A2 / (A1 + eps);
                
                raw_data{di}.t = sim.t;
                raw_data{di}.Id = sim.Id;
                raw_data{di}.Vg = Vg;
                raw_data{di}.A1 = A1;
                raw_data{di}.A2 = A2;
                raw_data{di}.baseline = I_base;
            end
            
            result.setData('dt_tau', dt_vals / tau);
            result.setData('PPX', PPX);
            result.setData('raw_data', raw_data);
            result.setParameter('Vg_pulse', Vg_pulse);
            result.setParameter('Vds', Vds);
        end
        
        function result = runVgTrainAmp(obj, result, tau)
            Vg_base = 0;
            Vds = -0.2;
            pulse_interval = obj.config.gap_tau * tau;
            t_pulse_w = obj.config.pulse_width_tau * tau;
            n_pulses = obj.config.n_pulses;
            Vg_amps = [0.4, 0.2, -0.2, -0.4];
            
            settle_before = 5 * tau;
            t_total = settle_before + n_pulses * (t_pulse_w + pulse_interval) + settle_before;
            nPts = max(30000, round(t_total / (tau / 50)));
            t = linspace(0, t_total, nPts);
            
            peaks = cell(length(Vg_amps), 1);
            labels = cell(length(Vg_amps), 1);
            
            for ai = 1:length(Vg_amps)
                Vg_amp = Vg_amps(ai);
                Vg = Vg_base * ones(size(t));
                pulse_starts = zeros(1, n_pulses);
                
                for p = 1:n_pulses
                    ps = settle_before + (p-1) * (t_pulse_w + pulse_interval);
                    pe = ps + t_pulse_w;
                    pulse_starts(p) = ps;
                    Vg(t >= ps & t < pe) = Vg_amp;
                end
                
                sim = obj.model.simulate(Vg, t, Vds);
                
                pks = zeros(1, n_pulses);
                for p = 1:n_pulses
                    ps = pulse_starts(p);
                    pe = ps + t_pulse_w;
                    mask = sim.t >= ps & sim.t <= pe;
                    I_p = sim.Id(mask);
                    if ~isempty(I_p)
                        if Vg_amp < Vg_base
                            pks(p) = min(I_p);
                        else
                            pks(p) = max(I_p);
                        end
                    end
                end
                
                peaks{ai} = abs(pks);
                labels{ai} = sprintf('Vg=%.1fV', Vg_amp);
            end
            
            result.setData('peaks', peaks);
            result.setData('labels', labels);
            result.setData('n_pulses', n_pulses);
            result.setParameter('pulse_width', t_pulse_w);
            result.setParameter('interval', pulse_interval);
            result.setParameter('Vg_amps', Vg_amps);
            result.setParameter('Vds', Vds);
        end
        
        function result = runVgTrainInterval(obj, result, tau)
            Vg_base = 0;
            Vg_amp = -0.2;
            Vds = -0.2;
            t_pulse_w = obj.config.pulse_width_tau * tau;
            n_pulses = obj.config.n_pulses;
            interval_mult = [0.5, 1, 2, 3, 5];
            
            settle_before = 5 * tau;
            
            peaks = cell(length(interval_mult), 1);
            labels = cell(length(interval_mult), 1);
            
            for ii = 1:length(interval_mult)
                pulse_interval = interval_mult(ii) * tau;
                t_total = settle_before + n_pulses * (t_pulse_w + pulse_interval) + settle_before;
                nPts = max(30000, round(t_total / (tau / 50)));
                t = linspace(0, t_total, nPts);
                
                Vg = Vg_base * ones(size(t));
                pulse_starts = zeros(1, n_pulses);
                
                for p = 1:n_pulses
                    ps = settle_before + (p-1) * (t_pulse_w + pulse_interval);
                    pe = ps + t_pulse_w;
                    pulse_starts(p) = ps;
                    Vg(t >= ps & t < pe) = Vg_amp;
                end
                
                sim = obj.model.simulate(Vg, t, Vds);
                
                pks = zeros(1, n_pulses);
                for p = 1:n_pulses
                    ps = pulse_starts(p);
                    pe = ps + t_pulse_w;
                    mask = sim.t >= ps & sim.t <= pe;
                    I_p = sim.Id(mask);
                    if ~isempty(I_p)
                        pks(p) = min(I_p);
                    end
                end
                
                peaks{ii} = abs(pks);
                labels{ii} = sprintf('%.1f\\tau', interval_mult(ii));
            end
            
            result.setData('peaks', peaks);
            result.setData('labels', labels);
            result.setData('n_pulses', n_pulses);
            result.setParameter('pulse_width', t_pulse_w);
            result.setParameter('interval_mult', interval_mult);
            result.setParameter('Vg_amp', Vg_amp);
            result.setParameter('Vds', Vds);
        end
        
        function result = runVdTrainAmp(obj, result, tau)
            Vgs = -0.2;
            Vds_base = -0.2;
            pulse_interval = obj.config.gap_tau * tau;
            t_pulse_w = obj.config.pulse_width_tau * tau;
            n_pulses = obj.config.n_pulses;
            Vds_amps = [0.4, 0.2, -0.2, -0.4];
            
            settle_before = 5 * tau;
            t_total = settle_before + n_pulses * (t_pulse_w + pulse_interval) + settle_before;
            nPts = max(30000, round(t_total / (tau / 50)));
            t = linspace(0, t_total, nPts);
            
            Vg = Vgs * ones(size(t));
            
            peaks = cell(length(Vds_amps), 1);
            labels = cell(length(Vds_amps), 1);
            
            for ai = 1:length(Vds_amps)
                Vds_amp = Vds_amps(ai);
                Vds_train = Vds_base * ones(size(t));
                pulse_starts = zeros(1, n_pulses);
                
                for p = 1:n_pulses
                    ps = settle_before + (p-1) * (t_pulse_w + pulse_interval);
                    pe = ps + t_pulse_w;
                    pulse_starts(p) = ps;
                    Vds_train(t >= ps & t < pe) = Vds_amp;
                end
                
                sim = obj.model.simulate(Vg, t, Vds_train);
                
                pks = zeros(1, n_pulses);
                for p = 1:n_pulses
                    ps = pulse_starts(p);
                    pe = ps + t_pulse_w;
                    mask = sim.t >= ps & sim.t <= pe;
                    I_p = sim.Id(mask);
                    if ~isempty(I_p)
                        if Vds_amp < Vds_base
                            pks(p) = min(I_p);
                        else
                            pks(p) = max(I_p);
                        end
                    end
                end
                
                peaks{ai} = abs(pks);
                labels{ai} = sprintf('Vds=%.1fV', Vds_amp);
            end
            
            result.setData('peaks', peaks);
            result.setData('labels', labels);
            result.setData('n_pulses', n_pulses);
            result.setParameter('pulse_width', t_pulse_w);
            result.setParameter('interval', pulse_interval);
            result.setParameter('Vds_amps', Vds_amps);
            result.setParameter('Vgs', Vgs);
        end
        
        function result = runVdTrainInterval(obj, result, tau)
            Vgs = -0.2;
            Vds_base = -0.2;
            Vds_amp = -0.4;
            t_pulse_w = obj.config.pulse_width_tau * tau;
            n_pulses = obj.config.n_pulses;
            interval_mult = [0.5, 1, 2, 3, 5];
            
            settle_before = 5 * tau;
            
            peaks = cell(length(interval_mult), 1);
            labels = cell(length(interval_mult), 1);
            
            for ii = 1:length(interval_mult)
                pulse_interval = interval_mult(ii) * tau;
                t_total = settle_before + n_pulses * (t_pulse_w + pulse_interval) + settle_before;
                nPts = max(30000, round(t_total / (tau / 50)));
                t = linspace(0, t_total, nPts);
                
                Vg = Vgs * ones(size(t));
                Vds_train = Vds_base * ones(size(t));
                pulse_starts = zeros(1, n_pulses);
                
                for p = 1:n_pulses
                    ps = settle_before + (p-1) * (t_pulse_w + pulse_interval);
                    pe = ps + t_pulse_w;
                    pulse_starts(p) = ps;
                    Vds_train(t >= ps & t < pe) = Vds_amp;
                end
                
                sim = obj.model.simulate(Vg, t, Vds_train);
                
                pks = zeros(1, n_pulses);
                for p = 1:n_pulses
                    ps = pulse_starts(p);
                    pe = ps + t_pulse_w;
                    mask = sim.t >= ps & sim.t <= pe;
                    I_p = sim.Id(mask);
                    if ~isempty(I_p)
                        pks(p) = min(I_p);
                    end
                end
                
                peaks{ii} = abs(pks);
                labels{ii} = sprintf('%.1f\\tau', interval_mult(ii));
            end
            
            result.setData('peaks', peaks);
            result.setData('labels', labels);
            result.setData('n_pulses', n_pulses);
            result.setParameter('pulse_width', t_pulse_w);
            result.setParameter('interval_mult', interval_mult);
            result.setParameter('Vds_amp', Vds_amp);
            result.setParameter('Vgs', Vgs);
        end
        
        function result = runVdsPulse(obj, result, tau)
            k_settle = 5;
            t_total = 3 * k_settle * tau;
            t = linspace(0, t_total, 10000);
            
            Vg = -0.2 * ones(size(t));
            
            t_pulse_start = k_settle * tau;
            t_pulse_end = 2 * k_settle * tau;
            
            Vds = -0.2 * ones(size(t));
            Vds(t > t_pulse_start & t < t_pulse_end) = -0.4;
            
            sim = obj.model.simulate(Vg, t, Vds);
            
            result.setData('t', sim.t);
            result.setData('Id', sim.Id);
            result.setData('Vg', Vg);
            result.setData('Vds', Vds);
            result.setParameter('tau', tau);
        end
        
        function tau = getTau(obj)
            % Get time constant from model
            if isa(obj.model, 'OECT.BisquertModel')
                tau = obj.model.parameters.tau_de;
            elseif isa(obj.model, 'OECT.ShirinskayaModel')
                p = obj.model.parameters;
                tau = p.Cd * p.Rd * p.Rs / (p.Rd + p.Rs);
            else
                tau = 0.01;
            end
        end
        
        function names = getTestNames(obj)
            names = {'Step', 'Transfer', 'Output', 'Hysteresis', ...
                'PPX', 'Vg Train (Amp)', 'Vg Train (Interval)', ...
                'Vd Train (Amp)', 'Vd Train (Interval)', 'Vds Pulse'};
        end
        
        function stop(obj)
            obj.stopFlag = true;
            if ~isempty(obj.model)
                obj.model.setStopFlag(true);
            end
        end
        
        function summary = getSummary(obj)
            summary = struct();
            summary.n_tests = length(obj.results);
            summary.test_names = cellfun(@(r) r.testName, obj.results, 'UniformOutput', false);
            summary.timestamp = datestr(now);
        end
    end
end