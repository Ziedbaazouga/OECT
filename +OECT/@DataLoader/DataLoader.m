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
            obj.log.info('Loading steady-state: %s', filename);
            
            if ~isfile(filename)
                obj.log.error('File not found: %s', filename);
                error('File not found: %s', filename);
            end
            
            sheets = sheetnames(filename);
            obj.log.debug('Found %d sheets', length(sheets));
            
            allData = struct();
            for s = 1:length(sheets)
                tbl = readtable(filename, 'Sheet', sheets{s});
                allData.(matlab.lang.makeValidName(sheets{s})) = table2array(tbl);
                obj.log.debug('Sheet %s: %d x %d', sheets{s}, size(allData.(matlab.lang.makeValidName(sheets{s})), 1), size(allData.(matlab.lang.makeValidName(sheets{s})), 2));
            end
            
            obj.steadyState.filename = filename;
            obj.steadyState.sheets = sheets;
            obj.steadyState.raw = allData;
            obj.steadyState.parsed = obj.parseSteadyStateData(allData, sheets);
            
            obj.isLoaded = true;
            obj.log.info('Steady-state loaded successfully');
        end
        
        function loadTransient(obj, filenames)
            if ischar(filenames) || isstring(filenames)
                filenames = cellstr(filenames);
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
    %#ok<INUSD> obj
    nVg = 17;
    nVd = 9;
    
    validSheets = {};
    stackGate = [];
    stackVd = [];
    stackId = [];
    
    for s = 1:length(sheets)
        fn = matlab.lang.makeValidName(sheets{s});
        data = allData.(fn);
        
        minCols = 1 + 5*(nVd-1) + 1; % max needed column index
        if size(data,1) < nVg || size(data,2) < minCols
            continue; % skip Calc/summary sheets
        end
        
        gate = data(1:nVg, 4);
        vd = zeros(nVd,1);
        id = zeros(nVg,nVd);
        
        for v = 1:nVd
            colV = 2 + 5*(v-1);
            colI = 1 + 5*(v-1);
            vd(v) = data(1, colV);
            id(:,v) = data(1:nVg, colI);
        end
        
        stackGate(:,end+1) = gate; %#ok<AGROW>
        stackVd(:,end+1) = vd; %#ok<AGROW>
        stackId(:,:,end+1) = id; %#ok<AGROW>
        validSheets{end+1} = sheets{s}; %#ok<AGROW>
    end
    
    if isempty(validSheets)
        error('No valid steady-state sheets found (expected >=17 rows and required columns)');
    end
    
    parsed.gateVoltage = mean(stackGate, 2);
    parsed.drainVoltage = mean(stackVd, 2)';
    parsed.drainCurrent = mean(stackId, 3);
    parsed.nSheets = numel(validSheets);
    parsed.sheetsUsed = validSheets;
    
    [parsed.Vg_sorted, idxVg] = sort(parsed.gateVoltage(:), 'ascend');
    [parsed.Vd_sorted, idxVd] = sort(parsed.drainVoltage(:), 'ascend');
    parsed.Id_matrix = parsed.drainCurrent(idxVg, idxVd);
end
        
        function parsed = parseTransientData(obj, data, sheets, filename)
            parsed = struct();
            parsed.time = [];
            parsed.drainCurrent = [];
            parsed.drainVoltage = [];
            parsed.gateVoltage = [];
            parsed.sheets = {};
            
            parsed = obj.parseFilename(filename, parsed);
            
            startRow = obj.config.defaultStartRow;
            endRow = obj.config.defaultEndRow;
            
            for s = 1:length(sheets)
                d = data{s};
                
                if size(d, 1) >= endRow && size(d,2) >= 5
                    t = d(startRow:endRow, 1) - d(startRow, 1);
                    Id = d(startRow:endRow, 3);
                    Vd = d(startRow:endRow, 2);
                    Vg = d(startRow:endRow, 5);
                    
                    parsed.time = [parsed.time; t(:)];
                    parsed.drainCurrent = [parsed.drainCurrent; Id(:)];
                    parsed.drainVoltage = [parsed.drainVoltage; Vd(:)];
                    parsed.gateVoltage = [parsed.gateVoltage; Vg(:)];
                    parsed.sheets{end+1} = sheets{s};
                end
            end
            
            valid = isfinite(parsed.time) & isfinite(parsed.drainCurrent) & parsed.time > 0;
            parsed.time = parsed.time(valid);
            parsed.drainCurrent = parsed.drainCurrent(valid);
            parsed.drainVoltage = parsed.drainVoltage(valid);
            parsed.gateVoltage = parsed.gateVoltage(valid);
            
            parsed.Vgs = unique(parsed.gateVoltage);
            parsed.Vds = unique(parsed.drainVoltage);
        end
        
        function parsed = parseFilename(obj, filename, parsed)
            %#ok<INUSD> obj
            [~, name, ~] = fileparts(filename);
            
            tokens = regexp(lower(name), '([+-]?\d+\.?\d*)\s*vd\s*([+-]?\d+\.?\d*)\s*vg', 'tokens');
            if ~isempty(tokens)
                parsed.filename_Vds = str2double(tokens{1}{1});
                parsed.filename_Vgs = str2double(tokens{1}{2});
            else
                parsed.filename_Vds = NaN;
                parsed.filename_Vgs = NaN;
            end
        end
        
        function setupDefaults(obj)
            if ~isfield(obj.config,'defaultStartRow'), obj.config.defaultStartRow = 68; end
            if ~isfield(obj.config,'defaultEndRow'), obj.config.defaultEndRow = 2030; end
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