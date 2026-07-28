classdef DataLoader < handle
    properties
        logger
        steadyState
        transient
        isLoaded logical = false
    end

    methods
        function obj = DataLoader()
            obj.logger = OECT.Logger('DataLoader');
            obj.steadyState = struct();
            obj.transient = struct();
        end

        function loadSteadyState(obj, file_name_steadystate, sheetnames_steadystate)
            if nargin < 3 || isempty(sheetnames_steadystate)
                sheetnames_steadystate = sheetnames(file_name_steadystate);
            end
            if isstring(sheetnames_steadystate), sheetnames_steadystate = cellstr(sheetnames_steadystate); end

            nSheets = numel(sheetnames_steadystate);
            tables = cell(nSheets,1);
            for s = 1:nSheets
                tables{s} = readtable(file_name_steadystate, 'Sheet', sheetnames_steadystate{s});
            end

            obj.steadyState.filePath = file_name_steadystate;
            obj.steadyState.sheetNames = sheetnames_steadystate;
            obj.steadyState.tables = tables;

            % Parse the raw sheets into a Vg/Vd/Id grid (used by models such
            % as OECT.ShirinskayaModel that need steady-state conductance
            % reconstruction). Fall back to an empty-but-valid struct so
            % that consumers can still safely use dot-indexing on it.
            try
                obj.steadyState.parsed = obj.parseSteadyStateBlocks(tables);
            catch parseErr
                obj.logger.warn('Could not parse steady-state blocks: %s', parseErr.message);
                obj.steadyState.parsed = struct('Vg_sorted', [], 'Vd_sorted', [], 'Id_matrix', []);
            end
            obj.logger.info('Steady-state data loaded successfully');

            obj.updateIsLoaded();
        end

        function loadTransient(obj, file_name_transient, sheetnames_transient)
            if ischar(file_name_transient), file_name_transient = {file_name_transient}; end
            if isstring(file_name_transient), file_name_transient = cellstr(file_name_transient); end
            if nargin < 3 || isempty(sheetnames_transient), sheetnames_transient = {'Run1','Run2'}; end
            if isstring(sheetnames_transient), sheetnames_transient = cellstr(sheetnames_transient); end

            nFiles = numel(file_name_transient);
            parsed = cell(nFiles,1);

            for k = 1:nFiles
                thisFile = file_name_transient{k};

                % old-old compatible: use first sheet in list for parsing
                thisSheet = sheetnames_transient{1};
                tbl = readtable(thisFile, 'Sheet', thisSheet);
                A = table2array(tbl);

                rec = struct();
                rec.filePath = thisFile;
                rec.sheet = thisSheet;

                % old-old indexing
                rec.time = A(68:2030,1) - A(68,1);
                rec.drainCurrent = A(68:2030,3);

                % filename biases parsed from naming convention
                [rec.filename_Vds, rec.filename_Vgs] = obj.parseBiasFromFilename(thisFile);

                parsed{k} = rec;
            end

            obj.transient.filePaths = file_name_transient;
            obj.transient.sheetNames = sheetnames_transient;
            obj.transient.parsed = parsed;
            obj.transient.filenames = file_name_transient; % GUI compatibility
            obj.logger.info('Transient data loaded successfully');

            obj.updateIsLoaded();
        end

        function [Vds, Vgs] = parseBiasFromFilename(~, filePath)
            [~, nm, ~] = fileparts(filePath);
            s = lower(nm);
            tok = regexp(s, '([-\d]+)\s*vd\s*([-\d]+)\s*vg', 'tokens', 'once');

            if isempty(tok)
                Vds = -0.1; Vgs = 0;
                return;
            end

            Vds = str2double(tok{1})/10;
            Vgs = str2double(tok{2})/10;
        end
    end

    methods (Access = private)
        function updateIsLoaded(obj)
            %UPDATEISLOADED  Mark the loader as loaded once both steady-state
            %   and transient data have been read in.
            obj.isLoaded = isfield(obj.steadyState, 'tables') && ~isempty(obj.steadyState.tables) ...
                && isfield(obj.transient, 'parsed') && ~isempty(obj.transient.parsed);
        end

        function parsed = parseSteadyStateBlocks(obj, tables)
            %PARSESTEADYSTATEBLOCKS  Reconstruct a Vg/Vd/Id grid from the raw
            %   steady-state sheets (5-column repeating blocks: DrainI,
            %   DrainV, <unused>, GateV, <unused>), averaged across sheets.
            nSheets = numel(tables);

            d0 = obj.tableToNumeric(tables{1});
            keep0 = any(isfinite(d0), 2);
            d0 = d0(keep0, :);

            [nr0, nc0] = size(d0);
            nVd = min(9, floor((nc0 - 2)/5) + 1);
            nVg = min(17, nr0);

            if nVg < 5 || nVd < 3
                error('Steady-state sheet format unsupported after header cleanup.');
            end

            gate_Voltage = nan(nVg, 1, nSheets);
            drain_Voltage = nan(1, nVd, nSheets);
            Id_meas_all = nan(nVg, nVd, nSheets);

            for s = 1:nSheets
                data = obj.tableToNumeric(tables{s});
                keep = any(isfinite(data), 2);
                data = data(keep, :);

                [nr, nc] = size(data);
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
            Id_matrix = Id_raw(idxVg, idxVd);

            parsed = struct('Vg_sorted', Vg_sorted, 'Vd_sorted', Vd_sorted, 'Id_matrix', Id_matrix);
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
    end
end