classdef DataLoader < handle
    %OECT.DATALOADER Unified data loading and preprocessing
    
    properties (SetAccess = private)
        steadyState struct = struct()
        transient struct = struct()
        staircase struct = struct()
        processed struct = struct()
        isLoaded logical = false
        log
    end
    
    properties (Access = private)
        config struct
    end
    
    methods
        function obj = DataLoader(config)
            if nargin < 1
                obj.config = struct();
            else
                obj.config = config;
            end
            obj.log = OECT.Logger('DataLoader');
            obj.setupDefaults();
        end
        
        function loadSteadyState(obj, filename)
            % Load steady-state measurement file
            obj.log.info('Loading steady-state: %s', filename);
            
            if ~isfile(filename)
                obj.log.error('File not found: %s', filename);
                error('File not found: %s', filename);
            end
            
            % Get sheet names
            sheets = sheetnames(filename);
            obj.log.debug('Found %d sheets', length(sheets));
            
            % Load all sheets
            allData = struct();
            for s = 1:length(sheets)
                tbl = readtable(filename, 'Sheet', sheets{s});
                allData.(sheets{s}) = table2array(tbl);
                obj.log.debug('Sheet %s: %d x %d', sheets{s}, size(allData.(sheets{s}), 1), size(allData.(sheets{s}), 2));
            end
            
            % Store raw data
            obj.steadyState.filename = filename;
            obj.steadyState.sheets = sheets;
            obj.steadyState.raw = allData;
            
            % Parse data structure
            obj.steadyState.parsed = obj.parseSteadyStateData(allData, sheets);
            
            obj.isLoaded = true;
            obj.log.info('Steady-state loaded successfully');
        end
        
        function loadTransient(obj, filenames)
            % Load transient measurement files
            if ischar(filenames)
                filenames = {filenames};
            end
            
            obj.log.info('Loading %d transient files', length(filenames));
            
            obj.transient.filenames = filenames;
            obj.transient.raw = cell(length(filenames), 1);
            obj.transient.parsed = cell(length(filenames), 1);
            
            for i = 1:length(filenames)
                if ~isfile(filenames{i})
                    obj.log.error('File not found: %s', filenames{i});
                    error('File not found: %s', filenames{i});
                end
                
                sheets = sheetnames(filenames{i});
                data = cell(length(sheets), 1);
                
                for s = 1:length(sheets)
                    tbl = readtable(filenames{i}, 'Sheet', sheets{s});
                    data{s} = table2array(tbl);
                end
                
                obj.transient.raw{i} = data;
                obj.transient.parsed{i} = obj.parseTransientData(data, sheets, filenames{i});
                
                obj.log.debug('Loaded transient %d: %s (%d sheets)', i, filenames{i}, length(sheets));
            end
            
            obj.isLoaded = true;
            obj.log.info('Transient data loaded successfully');
        end
        
        function parsed = parseSteadyStateData(obj, allData, sheets)
            % Parse steady-state data structure
            % Assumes standard format: 17 Vg rows, 9 Vd columns
            
            nSheets = length(sheets);
            nVg = 17;
            nVd = 9;
            
            gateVoltage = zeros(nVg, 1, nSheets);
            drainVoltage = zeros(1, nVd, nSheets);
            drainCurrent = zeros(nVg, nVd, nSheets);
            
            for s = 1:nSheets
                data = allData.(sheets{s});
                
                % Column 4 is gate voltage
                gateVoltage(:,1,s) = data(1:nVg, 4);
                
                % Drain voltages at row 1, columns 2, 7, 12, ...
                for v = 1:nVd
                    drainVoltage(1, v, s) = data(1, 2 + 5*(v-1));
                    drainCurrent(:, v, s) = data(1:nVg, 1 + 5*(v-1));
                end
            end
            
            parsed.gateVoltage = mean(gateVoltage, 3);
            parsed.drainVoltage = mean(drainVoltage, 3);
            parsed.drainCurrent = mean(drainCurrent, 3);
            parsed.nSheets = nSheets;
            parsed.Vg_unique = unique(parsed.gateVoltage);
            parsed.Vd_unique = unique(parsed.drainVoltage);
            
            % Sort by voltage
            [parsed.Vg_sorted, idxVg] = sort(parsed.Vg_unique);
            [parsed.Vd_sorted, idxVd] = sort(parsed.Vd_unique);
            
            % Reorder current matrix
            Vg_idx = arrayfun(@(v) find(parsed.Vg_unique == v, 1), parsed.gateVoltage);
            Vd_idx = arrayfun(@(v) find(parsed.Vd_unique == v, 1), parsed.drainVoltage);
            
            parsed.Id_matrix = zeros(length(parsed.Vg_sorted), length(parsed.Vd_sorted));
            for i = 1:length(parsed.Vg_sorted)
                for j = 1:length(parsed.Vd_sorted)
                    mask = Vg_idx == i & Vd_idx == j;
                    if any(mask)
                        parsed.Id_matrix(i, j) = mean(parsed.drainCurrent(mask));
                    end
                end
            end
        end
        
        function parsed = parseTransientData(obj, data, sheets, filename)
            % Parse transient data structure
            % Assumes standard format: time, drain voltage, drain current, gate voltage
            
            parsed = struct();
            parsed.time = [];
            parsed.drainCurrent = [];
            parsed.drainVoltage = [];
            parsed.gateVoltage = [];
            parsed.sheets = {};
            
            % Extract Vgs and Vds from filename
            parsed = obj.parseFilename(filename, parsed);
            
            for s = 1:length(sheets)
                sheet = sheets{s};
                d = data{s};
                
                % Row 68-2030 contains the transient data (from your file)
                startRow = 68;
                endRow = 2030;
                
                if size(d, 1) >= endRow
                    t = d(startRow:endRow, 1) - d(startRow, 1);
                    Id = d(startRow:endRow, 3);
                    Vd = d(startRow:endRow, 2);
                    Vg = d(startRow:endRow, 5);
                    
                    parsed.time = [parsed.time; t(:)];
                    parsed.drainCurrent = [parsed.drainCurrent; Id(:)];
                    parsed.drainVoltage = [parsed.drainVoltage; Vd(:)];
                    parsed.gateVoltage = [parsed.gateVoltage; Vg(:)];
                    parsed.sheets{end+1} = sheet;
                end
            end
            
            % Remove invalid values
            valid = isfinite(parsed.drainCurrent) & parsed.time > 0;
            parsed.time = parsed.time(valid);
            parsed.drainCurrent = parsed.drainCurrent(valid);
            parsed.drainVoltage = parsed.drainVoltage(valid);
            parsed.gateVoltage = parsed.gateVoltage(valid);
            
            % Determine Vgs and Vds from data
            parsed.Vgs = unique(parsed.gateVoltage);
            parsed.Vds = unique(parsed.drainVoltage);
        end
        
        function parsed = parseFilename(obj, filename, parsed)
            % Parse Vgs and Vds from filename
            % Format: "-04 vd -02 vg.xls"
            
            [~, name, ~] = fileparts(filename);
            
            % Look for patterns
            tokens = regexp(name, '([+-]?\d+\.?\d*)\s*vd\s*([+-]?\d+\.?\d*)\s*vg', 'tokens');
            if ~isempty(tokens)
                parsed.filename_Vds = str2double(tokens{1}{1});
                parsed.filename_Vgs = str2double(tokens{1}{2});
            else
                parsed.filename_Vds = NaN;
                parsed.filename_Vgs = NaN;
            end
        end
        
        function setupDefaults(obj)
            obj.config.defaultStartRow = 68;
            obj.config.defaultEndRow = 2030;
        end
        
        function clearData(obj)
            obj.steadyState = struct();
            obj.transient = struct();
            obj.staircase = struct();
            obj.processed = struct();
            obj.isLoaded = false;
            obj.log.info('Data cleared');
        end
    end
end