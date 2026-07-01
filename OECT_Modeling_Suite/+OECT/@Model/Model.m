classdef (Abstract) Model < handle
    %OECT.MODEL Abstract base class for all OECT models
    
    properties (Access = protected)
        parameters
        logger
        modelName char = ''
        stopFlag logical = false
    end
    
    methods
        function obj = Model(parameters)
            if nargin > 0
                obj.parameters = parameters;
            else
                obj.parameters = OECT.Parameters('Bisquert');
            end
            obj.logger = OECT.Logger(obj.modelName);
        end
        
        function setParameters(obj, parameters)
            obj.parameters = parameters;
        end
        
        function params = getParameters(obj)
            params = obj.parameters;
        end
        
        function setStopFlag(obj, flag)
            obj.stopFlag = flag;
        end
        
        function resetStopFlag(obj)
            obj.stopFlag = false;
        end
        
        function checkStop(obj)
            if obj.stopFlag
                error('OECT:ModelCancelled', 'Simulation cancelled by user');
            end
        end
    end
    
    methods (Abstract)
        % Core simulation
        sim = simulate(obj, Vg, t, Vds)
        
        % Parameter fitting
        fitResults = fit(obj, data)
        
        % Model information
        name = getModelName(obj)
        description = getModelDescription(obj)
        paramNames = getParameterNames(obj)
        paramBounds = getParameterBounds(obj)
        
        % Static analysis
        [Vg, Id, gm] = transferCharacteristics(obj, Vg_range, Vds_fixed)
        [Vd, Id] = outputCharacteristics(obj, Vg_fixed, Vd_range)
    end
end