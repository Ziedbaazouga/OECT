classdef ImpedanceSDModel < OECT.ImpedanceModel
    %OECT.IMPEDANCESDMODEL  Impedance (Source to Drain) EIS model.
    %
    %  Circuit topology (source-to-drain measurement). The device is a
    %  series combination of two parasitic series resistances (r) around a
    %  three-way parallel network of the channel's inductive/resistive arm
    %  (R0 + jwL0), the channel resistance R1, and an ideal double-layer
    %  capacitor C1:
    %
    %  Z = 2*r + [(jwL0 + R0) || R1 || (1/(jwC1))]
    %
    %  Free parameters : r, R0, L0, R1, C1

    methods
        function obj = ImpedanceSDModel(parameters)
            if nargin < 1
                parameters = OECT.Parameters('Impedance_SD');
            end
            obj@OECT.ImpedanceModel(parameters);
        end

        % ----------------------------------------------------------------
        %  MODEL INTERFACE (required by OECT.Model / OECT.ImpedanceModel)
        % ----------------------------------------------------------------
        function name = getModelName(~)
            name = 'Impedance (Source to Drain)';
        end

        function description = getModelDescription(~)
            description = ['EIS impedance model for the source-to-drain ' ...
                'measurement. Circuit: Z = 2*r + [(jwL0+R0) || R1 || ' ...
                '(1/(jwC1))], where R0+jwL0 is the channel''s inductive/' ...
                'resistive arm, R1 the channel resistance, and C1 the ' ...
                'double-layer capacitance.'];
        end

        function paramNames = getParameterNames(~)
            paramNames = {'r','R0','L0','R1','C1'};
        end

        function bounds = getParameterBounds(obj)
            bounds = struct( ...
                'r',  [1e-3, 1e5], ...
                'R0', [1e-3, 1e6], ...
                'L0', [1e-12, 1e-1], ...
                'R1', [1e-3, 1e6], ...
                'C1', [1e-12, 1e-1]);
            bounds = obj.mergeUserBounds(bounds);
        end
    end

    % ------------------------------------------------------------------ %
    methods (Access = protected)
        function defaults = defaultParamValues(~)
            % [r R0 L0 R1 C1]
            defaults = [100, 1000, 1e-6, 500, 1e-6];
        end

        function units = paramUnits(~)
            units = {'Ohm','Ohm','H','Ohm','F'};
        end
    end

    % ------------------------------------------------------------------ %
    methods (Static)
        function Z = circuitImpedance(w_vec, p, ~)
            %CIRCUITIMPEDANCE  Vectorised circuit evaluation.
            %  p = [r, R0, L0, R1, C1]
            r  = p(1); R0 = p(2); L0 = p(3); R1 = p(4); C1 = p(5);

            w  = w_vec(:);
            jw = 1i * w;

            Z_L    = R0 + jw * L0;                          % R0 + jwL0 arm
            Y_par  = 1 ./ Z_L + 1 / R1 + jw .* C1;           % admittance sum
            Z_par  = 1 ./ Y_par;                              % (jwL0+R0)||R1||1/(jwC1)

            Z = 2 * r + Z_par;
        end
    end
end
