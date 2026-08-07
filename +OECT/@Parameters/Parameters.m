classdef Parameters < handle
    %OECT.PARAMETERS Unified parameter container for all models
    %   This class provides a single source of truth for all model parameters.
    
    properties (SetAccess = private)
        % Model identification
        modelType char = 'Bisquert'
        version char = '2.0.0'
        
        % Geometry
        geometry struct = struct('d', 10e-6, 'L', 25e-6, 'W', 10e-6, 'T', 290)
        
        % Physical constants
        constants struct = struct('q', 1.602176634e-19, 'kB', 1.380649e-23)
        
        % Model-specific parameters (stored in nested struct)
        params struct = struct()
        
        % User-configurable fitting range (lower/upper bound) for each
        % model parameter, stored as paramBounds.(name) = [lb, ub].
        % Populated with model-specific defaults in initializeDefaultParams
        % and can be overridden (e.g. from the GUI) via setParamBounds().
        paramBounds struct = struct()
        
        % Metadata
        metadata struct = struct('fitDate', '', 'sourceFiles', {{}}, 'R2', [], 'RMSE', [])
        
        % Validation state
        isValid logical = false
        validationErrors cell = {}
    end
    
    properties (Dependent)
        % Convenience accessors
        P0
        M0
        tau_de
        f
        uc
        conductance_max
        Rs
        Rd
        Cd
        d
        L
        W
        T
        q
        kB
    end
    
    methods
        function obj = Parameters(modelType)
            % Constructor
            if nargin > 0
                if strcmp(modelType, 'Impedance')
                    % Backward-compatible alias: the plain 'Impedance' type
                    % now refers to the default (GS shortcut) EIS circuit.
                    modelType = 'Impedance_GS';
                end
                obj.modelType = modelType;
            end
            obj.metadata.fitDate = datestr(now);
            obj.initializeDefaultParams();
        end
        
        function initializeDefaultParams(obj)
            % Initialize default parameters based on model type
            switch obj.modelType
                case 'Bisquert'
                    obj.params.P0 = 1e26;
                    obj.params.M0 = 5e25;
                    obj.params.tau_de = 0.01;
                    obj.params.f = 0.5;
                    obj.params.uc = 0.05;
                    obj.params.holes_mobility = 2e-4;

                    obj.paramBounds = struct( ...
                        'P0',             [1e20, 1e30], ...
                        'M0',             [1e10, 1e30], ...
                        'tau_de',         [1e-9, 1e5], ...
                        'f',              [0,    1], ...
                        'uc',             [-5,   5], ...
                        'holes_mobility', [1e-8, 1]);
                    
                case 'Shirinskaya'
                    obj.params.conductance_max = 100;
                    obj.params.Rs = 2000;
                    obj.params.Rd = 150000;
                    obj.params.Cd = 3e-3;
                    obj.params.f = 0.5;
                    obj.params.holes_mobility = 2e-4;

                    obj.paramBounds = struct( ...
                        'conductance_max', [0.1,  1e6], ...
                        'Rs',              [1,    1e7], ...
                        'Rd',              [1,    1e9], ...
                        'Cd',              [1e-12, 1], ...
                        'f',               [0,    1], ...
                        'holes_mobility',  [1e-6, 1]);
                    
                case 'Impedance_GS'
                    % EIS circuit parameters – Impedance (GS shortcut)
                    % Z = r + {[R2||(1/(Q2*(jw)^n2))] + [A/(jw)^nW] +
                    %          [R1||(1/(Q1*(jw)^n1))] + R3 + r} || [R0+jwL0+r] + Rload
                    obj.params.R0    = 1e3;    % Ohm   – channel/inductive arm resistance
                    obj.params.L0    = 1e-6;   % H     – parasitic inductance
                    obj.params.Q1    = 1e-6;   % F.s^(n1-1) – double-layer CPE coefficient
                    obj.params.n1    = 0.9;    % -     – double-layer CPE exponent (1 = ideal C)
                    obj.params.R1    = 500;    % Ohm   – first RC pair resistance
                    obj.params.Q2    = 1e-7;   % F.s^(n2-1) – bulk ionic CPE coefficient
                    obj.params.n2    = 0.9;    % -     – bulk ionic CPE exponent (1 = ideal C)
                    obj.params.R2    = 2e3;    % Ohm   – second RC pair resistance
                    obj.params.A     = 1e4;    % Ohm.s^-nW – diffusion (Warburg-like) coefficient
                    obj.params.nW    = 0.5;    % -     – diffusion CPE exponent (0.5 = ideal Warburg)
                    obj.params.r     = 100;    % Ohm   – series parasitic resistance
                    obj.params.R3    = 50;     % Ohm   – additional series resistance
                    obj.params.Rload = 500;    % Ohm   – fixed load (not fitted)

                    obj.paramBounds = struct( ...
                        'R0', [1e-3,  1e6], ...
                        'L0', [1e-12, 1e-1], ...
                        'Q1', [1e-12, 1e-1], ...
                        'n1', [0.3,   1.0], ...
                        'R1', [1e-3,  1e6], ...
                        'Q2', [1e-12, 1e-1], ...
                        'n2', [0.3,   1.0], ...
                        'R2', [1e-3,  1e6], ...
                        'A',  [1e-6,  1e8], ...
                        'nW', [0.2,   0.8], ...
                        'r',  [1e-3,  1e5], ...
                        'R3', [0,     1e6]);

                case 'Impedance_SD'
                    % EIS circuit parameters – Impedance (Source to Drain)
                    % Z = 2*r + [(jwL0 + R0) || R1 || (1/(Q1*(jw)^n1))]
                    obj.params.r  = 100;    % Ohm – series parasitic resistance (x2)
                    obj.params.R0 = 1e3;    % Ohm – channel/inductive arm resistance
                    obj.params.L0 = 1e-6;   % H   – parasitic inductance
                    obj.params.R1 = 500;    % Ohm – channel resistance
                    obj.params.Q1 = 1e-6;   % F.s^(n1-1) – double-layer CPE coefficient
                    obj.params.n1 = 0.9;    % -   – double-layer CPE exponent (1 = ideal C)

                    obj.paramBounds = struct( ...
                        'r',  [1e-3,  1e5], ...
                        'R0', [1e-3,  1e6], ...
                        'L0', [1e-12, 1e-1], ...
                        'R1', [1e-3,  1e6], ...
                        'Q1', [1e-12, 1e-1], ...
                        'n1', [0.3,   1.0]);

                case 'Impedance_SDShort'
                    % EIS circuit parameters – Impedance (SD shortcut)
                    % Z = R3 + [R1||(1/(Q1*(jw)^n1))] + [1/(Q0*(jw)^n)] + r
                    obj.params.R3 = 50;     % Ohm       – series resistance
                    obj.params.R1 = 500;    % Ohm       – R||CPE pair resistance
                    obj.params.Q1 = 1e-6;   % F.s^(n1-1) – R||CPE pair CPE coefficient
                    obj.params.n1 = 0.9;    % -         – R||CPE pair CPE exponent (1 = ideal C)
                    obj.params.Q0 = 1e-6;   % F.s^(n-1) – CPE coefficient
                    obj.params.n  = 0.9;    % -         – CPE exponent (1 = ideal C)
                    obj.params.r  = 100;    % Ohm       – series parasitic resistance

                    obj.paramBounds = struct( ...
                        'R3', [0,     1e6], ...
                        'R1', [1e-3,  1e6], ...
                        'Q1', [1e-12, 1e-1], ...
                        'n1', [0.3,   1.0], ...
                        'Q0', [1e-12, 1e-1], ...
                        'n',  [0.3,   1.0], ...
                        'r',  [1e-3,  1e5]);

                otherwise
                    error('Unknown model type: %s', obj.modelType);
            end
        end
        
        function setGeometry(obj, d, L, W, T)
            obj.geometry.d = d;
            obj.geometry.L = L;
            obj.geometry.W = W;
            obj.geometry.T = T;
            obj.validate();
        end
        
        function setParameter(obj, name, value)
            % Set a single parameter with validation
            if isfield(obj.params, name)
                obj.params.(name) = value;
                obj.validate();
            else
                error('Parameter "%s" not found for model %s', name, obj.modelType);
            end
        end
        
        function value = getParameter(obj, name)
            if isfield(obj.params, name)
                value = obj.params.(name);
            else
                error('Parameter "%s" not found', name);
            end
        end

        function setParamBounds(obj, name, lb, ub)
            % Set the user-configurable fitting range [lb, ub] for a
            % single parameter. Used by the GUI to let users change the
            % range of fitting for any parameter of any model.
            if ~isfield(obj.params, name)
                error('Parameter "%s" not found for model %s', name, obj.modelType);
            end
            lb = double(lb); ub = double(ub);
            if ~isscalar(lb) || ~isscalar(ub) || ~isfinite(lb) || ~isfinite(ub)
                error('Bounds for "%s" must be finite scalar values', name);
            end
            if lb >= ub
                error('Lower bound must be less than upper bound for "%s"', name);
            end
            obj.paramBounds.(name) = [lb, ub];
        end

        function bounds = getParamBounds(obj, name)
            % Return the [lb, ub] fitting range for a parameter, or an
            % empty array if no bounds have been configured for it.
            if isfield(obj.paramBounds, name)
                bounds = obj.paramBounds.(name);
            else
                bounds = [];
            end
        end
        
        function params = getParameters(obj)
            % Return all parameters as a flat struct
            params = obj.params;
            params.d = obj.geometry.d;
            params.L = obj.geometry.L;
            params.W = obj.geometry.W;
            params.T = obj.geometry.T;
            params.q = obj.constants.q;
            params.kB = obj.constants.kB;
        end
        
        function validate(obj)
            % Validate all parameters against physical bounds
            obj.validationErrors = {};
            obj.isValid = true;
            
            switch obj.modelType
                case 'Bisquert'
                    obj.validateParam('P0', 0, 1e30);
                    obj.validateParam('M0', 0, 1e30);
                    obj.validateParam('tau_de', 1e-6, 100);
                    obj.validateParam('f', 0, 1);
                    obj.validateParam('uc', -5, 5);
                    obj.validateParam('holes_mobility', 1e-6, 1);
                    
                case 'Shirinskaya'
                    obj.validateParam('conductance_max', 0.1, 1e6);
                    obj.validateParam('Rs', 1, 1e7);
                    obj.validateParam('Rd', 1, 1e9);
                    obj.validateParam('Cd', 1e-12, 1);
                    obj.validateParam('f', 0, 1);
                    obj.validateParam('holes_mobility', 1e-6, 1);

                case 'Impedance_GS'
                    obj.validateParam('R0',    1e-3, 1e6);
                    obj.validateParam('L0',    1e-12, 1e-1);
                    obj.validateParam('Q1',    1e-12, 1e-1);
                    obj.validateParam('n1',    0, 1);
                    obj.validateParam('R1',    1e-3, 1e6);
                    obj.validateParam('Q2',    1e-12, 1e-1);
                    obj.validateParam('n2',    0, 1);
                    obj.validateParam('R2',    1e-3, 1e6);
                    obj.validateParam('A',     1e-6, 1e8);
                    obj.validateParam('nW',    0, 1);
                    obj.validateParam('r',     1e-3, 1e5);
                    obj.validateParam('R3',    0, 1e6);
                    obj.validateParam('Rload', 0, 1e6);

                case 'Impedance_SD'
                    obj.validateParam('r',  1e-3, 1e5);
                    obj.validateParam('R0', 1e-3, 1e6);
                    obj.validateParam('L0', 1e-12, 1e-1);
                    obj.validateParam('R1', 1e-3, 1e6);
                    obj.validateParam('Q1', 1e-12, 1e-1);
                    obj.validateParam('n1', 0, 1);

                case 'Impedance_SDShort'
                    obj.validateParam('R3', 0, 1e6);
                    obj.validateParam('R1', 1e-3, 1e6);
                    obj.validateParam('Q1', 1e-12, 1e-1);
                    obj.validateParam('n1', 0, 1);
                    obj.validateParam('Q0', 1e-12, 1e-1);
                    obj.validateParam('n',  0, 1);
                    obj.validateParam('r',  1e-3, 1e5);
            end
            
            % Validate geometry
            obj.validateParam('d', 1e-9, 1e-3, 'geometry');
            obj.validateParam('L', 1e-9, 1e-3, 'geometry');
            obj.validateParam('W', 1e-9, 1e-3, 'geometry');
            obj.validateParam('T', 200, 400, 'geometry');
        end
        
        function validateParam(obj, name, minVal, maxVal, structName)
            if nargin < 5
                structName = 'params';
            end
            if ~isfield(obj.(structName), name)
                obj.validationErrors{end+1} = sprintf('Missing parameter: %s', name);
                obj.isValid = false;
                return;
            end
            val = obj.(structName).(name);
            if val < minVal || val > maxVal
                obj.validationErrors{end+1} = sprintf('%s = %.4e out of range [%.4e, %.4e]', ...
                    name, val, minVal, maxVal);
                obj.isValid = false;
            end
        end
        
        % Dependent property accessors
        function val = get.P0(obj)
            if isfield(obj.params, 'P0'), val = obj.params.P0; else, val = NaN; end
        end
        function val = get.M0(obj)
            if isfield(obj.params, 'M0'), val = obj.params.M0; else, val = NaN; end
        end
        function val = get.tau_de(obj)
            if isfield(obj.params, 'tau_de'), val = obj.params.tau_de; else, val = NaN; end
        end
        function val = get.f(obj)
            if isfield(obj.params, 'f'), val = obj.params.f; else, val = NaN; end
        end
        function val = get.uc(obj)
            if isfield(obj.params, 'uc'), val = obj.params.uc; else, val = NaN; end
        end
        function val = get.conductance_max(obj)
            if isfield(obj.params, 'conductance_max'), val = obj.params.conductance_max; else, val = NaN; end
        end
        function val = get.Rs(obj)
            if isfield(obj.params, 'Rs'), val = obj.params.Rs; else, val = NaN; end
        end
        function val = get.Rd(obj)
            if isfield(obj.params, 'Rd'), val = obj.params.Rd; else, val = NaN; end
        end
        function val = get.Cd(obj)
            if isfield(obj.params, 'Cd'), val = obj.params.Cd; else, val = NaN; end
        end
        function val = get.d(obj)
            val = obj.geometry.d;
        end
        function val = get.L(obj)
            val = obj.geometry.L;
        end
        function val = get.W(obj)
            val = obj.geometry.W;
        end
        function val = get.T(obj)
            val = obj.geometry.T;
        end
        function val = get.q(obj)
            val = obj.constants.q;
        end
        function val = get.kB(obj)
            val = obj.constants.kB;
        end
    end
    
    methods (Static)
        function obj = fromStruct(S)
            % Create Parameters from a struct
            if ~isfield(S, 'modelType')
                error('Struct must contain modelType field');
            end
            obj = OECT.Parameters(S.modelType);
            
            % Copy fields
            fields = fieldnames(S);
            for i = 1:length(fields)
                fn = fields{i};
                if isprop(obj, fn)
                    obj.(fn) = S.(fn);
                elseif isfield(obj.params, fn)
                    obj.params.(fn) = S.(fn);
                elseif isfield(obj.geometry, fn)
                    obj.geometry.(fn) = S.(fn);
                end
            end
            obj.validate();
        end
        
        function obj = loadFromFile(filename)
            % Load parameters from MAT file
            if ~isfile(filename)
                error('File not found: %s', filename);
            end
            S = load(filename);
            if ~isfield(S, 'parameters')
                error('File must contain "parameters" variable');
            end
            obj = OECT.Parameters.fromStruct(S.parameters);
        end
    end
end