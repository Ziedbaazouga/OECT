classdef TestResult < handle
    %OECT.TESTRESULT Unified test result container
    
    properties
        testName char = ''
        testType char = ''  % 'step', 'transfer', 'output', etc.
        parameters struct = struct()
        data struct = struct()
        summary struct = struct()
        plots cell = {}
        metadata struct = struct('timestamp', '', 'modelName', '', 'version', '')
    end
    
    properties (Dependent)
        isValid logical
        hasData logical
        hasPlots logical
    end
    
    methods
        function obj = TestResult(testName, testType)
            if nargin > 0
                obj.testName = testName;
                obj.testType = testType;
            end
            obj.metadata.timestamp = datestr(now);
        end
        
        function setData(obj, field, value)
            obj.data.(field) = value;
        end
        
        function value = getData(obj, field)
            if isfield(obj.data, field)
                value = obj.data.(field);
            else
                value = [];
            end
        end
        
        function setParameter(obj, name, value)
            obj.parameters.(name) = value;
        end
        
        function addPlot(obj, plotHandle)
            obj.plots{end+1} = plotHandle;
        end
        
        function summary = computeSummary(obj)
            % Compute summary metrics based on test type
            switch obj.testType
                case 'transfer'
                    summary = obj.computeTransferSummary();
                case 'output'
                    summary = obj.computeOutputSummary();
                case 'hysteresis'
                    summary = obj.computeHysteresisSummary();
                case 'ppx'
                    summary = obj.computePPXSummary();
                otherwise
                    summary = struct();
            end
            obj.summary = summary;
        end
        
        function summary = computeTransferSummary(obj)
            summary = struct();
            if isfield(obj.data, 'Id') && isfield(obj.data, 'Vgs')
                Id = obj.data.Id;
                Vgs = obj.data.Vgs;
                
                % Find on/off ratio
                summary.on_ratio = max(abs(Id)) / (min(abs(Id)) + eps);
                summary.Vg_on = Vgs(abs(Id) == max(abs(Id)));
                summary.Vg_off = Vgs(abs(Id) == min(abs(Id)));
                
                % Threshold voltage (extrapolated)
                if length(Id) > 1
                    % Find point where Id crosses 10% of max
                    Id_norm = abs(Id) / max(abs(Id));
                    idx = find(Id_norm > 0.1, 1);
                    if ~isempty(idx) && idx > 1
                        summary.Vth = interp1([Id_norm(idx-1), Id_norm(idx)], ...
                            [Vgs(idx-1), Vgs(idx)], 0.1);
                    else
                        summary.Vth = NaN;
                    end
                end
            end
        end
        
        function summary = computeOutputSummary(obj)
            summary = struct();
            if isfield(obj.data, 'Id') && isfield(obj.data, 'Vds')
                Id = obj.data.Id;
                Vds = obj.data.Vds;
                summary.linear_region = max(abs(Id)) / (max(abs(Vds)) + eps);
                summary.max_current = max(abs(Id));
            end
        end
        
        function summary = computeHysteresisSummary(obj)
            summary = struct();
            if isfield(obj.data, 'Id_forward') && isfield(obj.data, 'Id_reverse')
                Id_fwd = obj.data.Id_forward;
                Id_rev = obj.data.Id_reverse;
                summary.hysteresis_width = mean(abs(Id_rev - Id_fwd));
                summary.hysteresis_area = trapz(abs(Id_rev - Id_fwd));
            end
        end
        
        function summary = computePPXSummary(obj)
            summary = struct();
            if isfield(obj.data, 'PPX')
                PPX = obj.data.PPX;
                summary.PPX_max = max(PPX);
                summary.PPX_min = min(PPX);
                summary.PPX_mean = mean(PPX);
                summary.facilitation = PPX(end) / (PPX(1) + eps);
            end
        end
        
        function save(obj, filename)
            if nargin < 2
                [~, name, ~] = fileparts(obj.testName);
                filename = sprintf('results/simulations/%s_%s.mat', ...
                    name, datestr(now, 'yyyy-mm-dd_HH-MM-SS'));
            end
            
            % Convert to struct for saving
            S = struct();
            S.testName = obj.testName;
            S.testType = obj.testType;
            S.parameters = obj.parameters;
            S.data = obj.data;
            S.summary = obj.summary;
            S.metadata = obj.metadata;
            
            save(filename, 'S');
        end
        
        function displaySummary(obj)
            if isempty(obj.summary)
                obj.computeSummary();
            end
            
            fprintf('\n=== Test: %s ===\n', obj.testName);
            fprintf('Type: %s\n', obj.testType);
            fprintf('Time: %s\n', obj.metadata.timestamp);
            
            fields = fieldnames(obj.summary);
            for i = 1:length(fields)
                fn = fields{i};
                val = obj.summary.(fn);
                if isnumeric(val) && numel(val) == 1
                    fprintf('  %s: %.4f\n', fn, val);
                elseif isnumeric(val) && numel(val) > 1
                    fprintf('  %s: [%d elements]\n', fn, length(val));
                else
                    fprintf('  %s: %s\n', fn, val);
                end
            end
        end
        
        function val = get.isValid(obj)
            val = ~isempty(obj.testName) && ~isempty(obj.testType);
        end
        
        function val = get.hasData(obj)
            val = ~isempty(fieldnames(obj.data));
        end
        
        function val = get.hasPlots(obj)
            val = ~isempty(obj.plots);
        end
    end
end