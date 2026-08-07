classdef ImpedanceSDModel < OECT.ImpedanceModel
    %OECT.IMPEDANCESDMODEL  Impedance (Source to Drain) EIS model.
    %
    %  Circuit topology (source-to-drain measurement). The device is a
    %  series combination of two parasitic series resistances (r) around a
    %  three-way parallel network of the channel's inductive/resistive arm
    %  (R0 + jwL0), the channel resistance R1, and a non-ideal double-layer
    %  capacitor modelled as a Constant Phase Element (CPE) Q1/n1:
    %
    %  Z = 2*r + [(jwL0 + R0) || R1 || (1/(Q1*(jw)^n1))]
    %
    %  The CPE (rather than an ideal capacitor) accounts for the depressed/
    %  rotated semicircle commonly observed in source-to-drain EIS data,
    %  where the low-frequency intercept does not sit exactly on the real
    %  axis as an ideal R||C network would force it to.
    %
    %  Free parameters : r, R0, L0, R1, Q1, n1

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
                '(1/(Q1*(jw)^n1))], where R0+jwL0 is the channel''s ' ...
                'inductive/resistive arm, R1 the channel resistance, and ' ...
                'the Q1/n1 branch is a Constant Phase Element capturing ' ...
                'non-ideal (depressed) double-layer capacitive behaviour.'];
        end

        function paramNames = getParameterNames(~)
            paramNames = {'r','R0','L0','R1','Q1','n1'};
        end

        function bounds = getParameterBounds(obj)
            bounds = struct( ...
                'r',  [1e-3, 1e5], ...
                'R0', [1e-3, 1e6], ...
                'L0', [1e-12, 1e-1], ...
                'R1', [1e-3, 1e6], ...
                'Q1', [1e-12, 1e-1], ...
                'n1', [0.3,   1.0]);
            bounds = obj.mergeUserBounds(bounds);
        end
    end

    % ------------------------------------------------------------------ %
    methods (Access = protected)
        function defaults = defaultParamValues(~)
            % [r R0 L0 R1 Q1 n1]
            defaults = [100, 1000, 1e-6, 500, 1e-6, 0.9];
        end

        function units = paramUnits(~)
            units = {'Ohm','Ohm','H','Ohm','F.s^(n1-1)','-'};
        end
    end

    % ------------------------------------------------------------------ %
    methods (Static)
        function Z = circuitImpedance(w_vec, p, ~)
            %CIRCUITIMPEDANCE  Vectorised circuit evaluation.
            %  p = [r, R0, L0, R1, Q1, n1]
            r  = p(1); R0 = p(2); L0 = p(3); R1 = p(4); Q1 = p(5); n1 = p(6);

            w  = w_vec(:);
            jw = 1i * w;

            Z_L    = R0 + jw * L0;                          % R0 + jwL0 arm
            Y_par  = 1 ./ Z_L + 1 / R1 + Q1 .* jw.^n1;       % admittance sum
            Z_par  = 1 ./ Y_par;                              % (jwL0+R0)||R1||1/(Q1*(jw)^n1)

            Z = 2 * r + Z_par;
        end
    end
end
