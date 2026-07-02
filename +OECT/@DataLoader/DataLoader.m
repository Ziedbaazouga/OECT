classdef DataLoader < handle
    properties
        logger
        steadyState
        transient
    end

    methods
        function obj = DataLoader()
            obj.logger = OECT.Logger('DataLoader');
            obj.steadyState = struct();
            obj.transient = struct();
        end

        function loadSteadyState(obj, file_name_steadystate, sheetnames_steadystate)
            if nargin < 3 || isempty(sheetnames_steadystate)
                [~, sheetnames_steadystate] = xlsfinfo(file_name_steadystate);
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
            obj.steadyState.parsed = [];   % old flow compatibility
            obj.logger.info('Steady-state data loaded successfully');
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
end