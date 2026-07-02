classdef StateManager < handle
    %OECT.GUISTATE State machine for GUI workflow
    
    properties (Access = private)
        currentState char = 'Idle'
        allowedTransitions struct = struct()
        callbacks struct = struct()
        logger OECT.Logger
    end
    
    properties (Constant)
        STATES = {'Idle', 'DataLoaded', 'Fitted', 'Testing', 'Results', 'Error'}
    end
    
    methods
        function obj = StateManager()
            obj.logger = OECT.Logger('StateManager');
            obj.setupTransitions();
        end
        
        function setupTransitions(obj)
            % Define allowed transitions
            obj.allowedTransitions.Idle = {'DataLoaded', 'Error'};
            obj.allowedTransitions.DataLoaded = {'Fitted', 'Idle', 'Error'};
            obj.allowedTransitions.Fitted = {'Testing', 'Idle', 'Error'};
            obj.allowedTransitions.Testing = {'Results', 'Fitted', 'Error'};
            obj.allowedTransitions.Results = {'Idle', 'Fitted', 'Testing', 'Error'};
            obj.allowedTransitions.Error = {'Idle', 'DataLoaded'};
        end
        
        function success = transition(obj, newState)
            % Attempt to transition to new state
            if ~ismember(newState, obj.STATES)
                obj.logger.error('Invalid state: %s', newState);
                success = false;
                return;
            end
            
            % Check if transition is allowed
            allowed = obj.allowedTransitions.(obj.currentState);
            if ~ismember(newState, allowed)
                obj.logger.warn('Transition %s -> %s not allowed', obj.currentState, newState);
                success = false;
                return;
            end
            
            % Execute transition callbacks
            if obj.executeCallbacks(obj.currentState, newState)
                obj.currentState = newState;
                obj.logger.info('State: %s -> %s', obj.currentState, newState);
                success = true;
            else
                success = false;
            end
        end
        
        function success = executeCallbacks(obj, fromState, toState)
            % Execute callbacks for state transition
            key = sprintf('%s->%s', fromState, toState);
            if isfield(obj.callbacks, key) && isa(obj.callbacks.(key), 'function_handle')
                try
                    obj.callbacks.(key)();
                    success = true;
                catch ME
                    obj.logger.error('Callback failed: %s', ME.message);
                    success = false;
                end
            else
                success = true;
            end
        end
        
        function registerCallback(obj, fromState, toState, callback)
            % Register a callback for state transition
            key = sprintf('%s->%s', fromState, toState);
            obj.callbacks.(key) = callback;
        end
        
        function state = getState(obj)
            state = obj.currentState;
        end
        
        function tf = isState(obj, state)
            tf = strcmp(obj.currentState, state);
        end
        
        function tf = canTransition(obj, newState)
            tf = ismember(newState, obj.STATES) && ...
                 ismember(newState, obj.allowedTransitions.(obj.currentState));
        end
        
        function reset(obj)
            obj.currentState = 'Idle';
            obj.logger.info('State reset to Idle');
        end
    end
end