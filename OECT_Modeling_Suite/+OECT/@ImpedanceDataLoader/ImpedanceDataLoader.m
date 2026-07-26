classdef ImpedanceDataLoader < handle
    %OECT.IMPEDANCEDATALOADER Loads EIS impedance data from xlsx files
    %
    %   Expected xlsx format:
    %     Sheet 1 (any name): Column A = Frequency (Hz)
    %     Sheet "Magnitude_Data": Column A = |Z| average (Ohm), Column B = Std Dev
    %     Sheet "Phase_Data":     Column A = Phase average (deg), Column B = Std Dev
    
    properties (SetAccess = private)
        frequency   % Hz
        magnitude   % Ohm  (|Z|)
        phase       % degrees
        Z_real      % Ohm
        Z_imag      % Ohm
        mag_std     % standard deviation of magnitude
        phase_std   % standard deviation of phase
        filename char = ''
        isLoaded logical = false
    end
    
    properties (Access = private)
        log
    end
    
    methods
        function obj = ImpedanceDataLoader()
            obj.log = OECT.Logger('ImpedanceDataLoader');
        end
        
        function loadFile(obj, filename)
            %LOADFILE  Load EIS data from an xlsx file.
            %   loadFile(filename) reads the xlsx workbook at the given path.
            
            if ~isfile(filename)
                error('OECT:FileNotFound', 'File not found: %s', filename);
            end
            
            obj.filename = filename;
            obj.log.info('Loading EIS file: %s', filename);
            
            sheets = sheetnames(filename);
            obj.log.debug('Found %d sheets: %s', length(sheets), strjoin(sheets, ', '));
            
            % --- Frequency ---
            freqSheet = obj.findSheet(sheets, {'Frequency', 'freq', 'Hz'}, 1);
            freqTable = readtable(filename, 'Sheet', freqSheet, 'ReadVariableNames', false);
            obj.frequency = freqTable{:, 1};
            obj.frequency = obj.frequency(isfinite(obj.frequency) & obj.frequency > 0);
            obj.log.debug('Frequency: %d points, %.1f – %.2e Hz', ...
                length(obj.frequency), min(obj.frequency), max(obj.frequency));
            
            % --- Magnitude ---
            magSheet = obj.findSheet(sheets, {'Magnitude', 'Mag', '|Z|'}, []);
            if isempty(magSheet)
                error('OECT:MissingSheet', ...
                    'Cannot find Magnitude sheet. Expected name containing "Magnitude" or "Mag".');
            end
            magTable = readtable(filename, 'Sheet', magSheet, 'ReadVariableNames', false);
            obj.magnitude = magTable{1:length(obj.frequency), 1};
            if size(magTable, 2) >= 2
                obj.mag_std = magTable{1:length(obj.frequency), 2};
            else
                obj.mag_std = zeros(length(obj.frequency), 1);
            end
            
            % --- Phase ---
            phaseSheet = obj.findSheet(sheets, {'Phase', 'Phi', 'Angle'}, []);
            if isempty(phaseSheet)
                error('OECT:MissingSheet', ...
                    'Cannot find Phase sheet. Expected name containing "Phase" or "Phi".');
            end
            phaseTable = readtable(filename, 'Sheet', phaseSheet, 'ReadVariableNames', false);
            obj.phase = phaseTable{1:length(obj.frequency), 1};
            if size(phaseTable, 2) >= 2
                obj.phase_std = phaseTable{1:length(obj.frequency), 2};
            else
                obj.phase_std = zeros(length(obj.frequency), 1);
            end
            
            % Align lengths
            n = min([length(obj.frequency), length(obj.magnitude), length(obj.phase)]);
            obj.frequency = obj.frequency(1:n);
            obj.magnitude = obj.magnitude(1:n);
            obj.phase     = obj.phase(1:n);
            obj.mag_std   = obj.mag_std(1:n);
            obj.phase_std = obj.phase_std(1:n);
            
            % Remove non-finite rows
            valid = isfinite(obj.frequency) & isfinite(obj.magnitude) & isfinite(obj.phase) ...
                    & obj.frequency > 0 & obj.magnitude > 0;
            obj.frequency = obj.frequency(valid);
            obj.magnitude = obj.magnitude(valid);
            obj.phase     = obj.phase(valid);
            obj.mag_std   = obj.mag_std(valid);
            obj.phase_std = obj.phase_std(valid);
            
            obj.computeComplexImpedance();
            
            obj.isLoaded = true;
            obj.log.info('EIS data loaded: %d points', length(obj.frequency));
        end
        
        function data = getData(obj)
            %GETDATA  Return all EIS data as a struct.
            if ~obj.isLoaded
                error('OECT:NotLoaded', 'No EIS data loaded. Call loadFile first.');
            end
            data.frequency = obj.frequency;
            data.magnitude = obj.magnitude;
            data.phase     = obj.phase;
            data.Z_real    = obj.Z_real;
            data.Z_imag    = obj.Z_imag;
            data.mag_std   = obj.mag_std;
            data.phase_std = obj.phase_std;
            data.filename  = obj.filename;
        end
    end
    
    methods (Access = private)
        function computeComplexImpedance(obj)
            %COMPUTECOMPLEXIMPEDANCE  Convert |Z| and phase (deg) to real/imag parts.
            phi_rad  = obj.phase * pi / 180;
            obj.Z_real = obj.magnitude .* cos(phi_rad);
            obj.Z_imag = obj.magnitude .* sin(phi_rad);
        end
        
        function hit = findSheet(obj, sheets, keywords, defaultIdx)
            %FINDSHEET  Return first sheet name whose title contains any keyword.
            %   Returns defaultIdx-th sheet name (or empty) when nothing matches.
            hit = '';
            for k = 1:length(keywords)
                for s = 1:length(sheets)
                    if contains(lower(sheets{s}), lower(keywords{k}))
                        hit = sheets{s};
                        return;
                    end
                end
            end
            if isempty(hit) && ~isempty(defaultIdx) && defaultIdx <= length(sheets)
                hit = sheets{defaultIdx};
            end
        end
    end
end
