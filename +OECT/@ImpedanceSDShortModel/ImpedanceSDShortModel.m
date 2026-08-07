classdef ImpedanceSDShortModel < OECT.ImpedanceModel
    %OECT.IMPEDANCESDSHORTMODEL  Impedance (SD shortcut) EIS model.
    %
    %  Circuit topology (source-drain shortcut). A series combination of
    %  a single R||CPE pair (R1||(1/(Q1*(jw)^n1))), replacing the former
    %  two separate R||C pairs, a second Constant Phase Element (CPE)
    %  branch, and two series resistances (R3, r):
    %
    %  Z = R3 + [R1||(1/(Q1*(jw)^n1))] + [1/(Q0*(jw)^n)] + r
    %
    %  Free parameters : R3, R1, Q1, n1, Q0, n, r

    methods
        function obj = ImpedanceSDShortModel(parameters)
            if nargin < 1
                parameters = OECT.Parameters('Impedance_SDShort');
            end
            obj@OECT.ImpedanceModel(parameters);
        end

        % ----------------------------------------------------------------
        %  MODEL INTERFACE (required by OECT.Model / OECT.ImpedanceModel)
        % ----------------------------------------------------------------
        function name = getModelName(~)
            name = 'Impedance (SD shortcut)';
        end

        function description = getModelDescription(~)
            description = ['EIS impedance model for the source-drain ' ...
                'shortcut configuration. Circuit: Z = R3 + ' ...
                '[R1||(1/(Q1*(jw)^n1))] + [1/(Q0*(jw)^n)] + r, where the ' ...
                'R1/Q1/n1 branch is a single Constant Phase Element ' ...
                'replacing the former two separate R||C pairs, and the ' ...
                'Q0/n branch is a Constant Phase Element capturing ' ...
                'non-ideal (depressed) diffusion/interfacial behaviour.'];
        end

        function paramNames = getParameterNames(~)
            paramNames = {'R3','R1','Q1','n1','Q0','n','r'};
        end

        function bounds = getParameterBounds(obj)
            bounds = struct( ...
                'R3', [0,     1e6], ...
                'R1', [1e-3,  1e6], ...
                'Q1', [1e-12, 1e-1], ...
                'n1', [0.3,   1.0], ...
                'Q0', [1e-12, 1e-1], ...
                'n',  [0.3,   1.0], ...
                'r',  [1e-3,  1e5]);
            bounds = obj.mergeUserBounds(bounds);
        end
    end

    % ------------------------------------------------------------------ %
    methods (Access = protected)
        function defaults = defaultParamValues(~)
            % [R3 R1 Q1 n1 Q0 n r]
            defaults = [50, 500, 1e-6, 0.9, 1e-6, 0.9, 100];
        end

        function units = paramUnits(~)
            units = {'Ohm','Ohm','F.s^(n1-1)','-','F.s^(n-1)','-','Ohm'};
        end
    end

    % ------------------------------------------------------------------ %
    methods (Static)
        function Z = circuitImpedance(w_vec, p, ~)
            %CIRCUITIMPEDANCE  Vectorised circuit evaluation.
            %  p = [R3, R1, Q1, n1, Q0, n, r]
            R3 = p(1); R1 = p(2); Q1 = p(3); n1 = p(4);
            Q0 = p(5); n  = p(6); r  = p(7);

            w  = w_vec(:);
            jw = 1i * w;

            Z_Q1  = 1 ./ (Q1 .* jw.^n1);
            Z_RC1 = (R1 .* Z_Q1) ./ (R1 + Z_Q1);   % R1 || CPE1

            Z_Q0  = 1 ./ (Q0 .* jw.^n);            % CPE branch

            Z = R3 + Z_RC1 + Z_Q0 + r;
        end
    end
end
