classdef Logger < handle
    %OECT.LOGGER Hierarchical logging system
    
    properties
        Level char = 'INFO'  % ERROR, WARN, INFO, DEBUG, TRACE
        LogFile char = 'oect_log.txt'
        ConsoleOutput logical = true
        MaxFileSize double = 10e6  % 10 MB
    end
    
    properties (Constant)
        LEVELS = struct('ERROR', 1, 'WARN', 2, 'INFO', 3, 'DEBUG', 4, 'TRACE', 5)
    end
    
    properties (Access = private)
        context char = ''
        fileId = -1
    end
    
    methods
        function obj = Logger(context)
            if nargin > 0
                obj.context = context;
            end
            obj.initLogFile();
        end
        
        function initLogFile(obj)
            % Initialize log file, rotate if too large
            if isfile(obj.LogFile)
                info = dir(obj.LogFile);
                if info.bytes > obj.MaxFileSize
                    backup = sprintf('%s.%s.bak', obj.LogFile, datestr(now, 'yyyy-mm-dd_HH-MM-SS'));
                    movefile(obj.LogFile, backup);
                end
            end
            obj.fileId = fopen(obj.LogFile, 'a');
            if obj.fileId == -1
                warning('Could not open log file: %s', obj.LogFile);
            end
        end
        
        function setLevel(obj, level)
            if isfield(obj.LEVELS, level)
                obj.Level = level;
            else
                error('Unknown log level: %s', level);
            end
        end
        
        function log(obj, level, message, varargin)
    if obj.LEVELS.(level) > obj.LEVELS.(obj.Level)
        return;
    end
    
    timestamp = datestr(now, 'yyyy-mm-dd HH:MM:SS');
    msg = sprintf(message, varargin{:});
    
    if ~isempty(obj.context)
        entry = sprintf('[%s] [%s] [%s] %s\n', timestamp, level, obj.context, msg);
    else
        entry = sprintf('[%s] [%s] %s\n', timestamp, level, msg);
    end
    
    if obj.ConsoleOutput
        if strcmp(level, 'ERROR')
            fprintf(2, entry);
        else
            fprintf(entry);
        end
    end
    
    if obj.fileId ~= -1
        fprintf(obj.fileId, entry);
        % fflush removed - not needed in MATLAB
    end
end
        
        function error(obj, message, varargin)
            obj.log('ERROR', message, varargin{:});
        end
        
        function warn(obj, message, varargin)
            obj.log('WARN', message, varargin{:});
        end
        
        function info(obj, message, varargin)
            obj.log('INFO', message, varargin{:});
        end
        
        function debug(obj, message, varargin)
            obj.log('DEBUG', message, varargin{:});
        end
        
        function trace(obj, message, varargin)
            obj.log('TRACE', message, varargin{:});
        end
        
        function delete(obj)
            if obj.fileId ~= -1
                fclose(obj.fileId);
            end
        end
    end
end