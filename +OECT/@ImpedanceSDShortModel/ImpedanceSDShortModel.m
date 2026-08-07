classdef ImpedanceSDShortModel < OECT.ImpedanceModel
    %OECT.IMPEDANCESDSHORTMODEL  Impedance (SD shortcut) EIS model.
    %
    %  Circuit topology (source-drain shortcut). A series combination of
    %  two RC pairs (R1||C1 and R2||C2), a Constant Phase Element (CPE)
    %  branch, and two series resistances (R3, r):
    %
    %  Z = R3 + [R1||(1/(jwC1))] + [1/(Q0*(jw)^n)] + r + [R2||(1/(jwC2))]
    %
    %  Free parameters : R3, R1, C1, Q0, n, r, R2, C2

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
                'shortcut configuration. Circuit: Z = R3 + [R1||(1/(jwC1))] ' ...
                '+ [1/(Q0*(jw)^n)] + r + [R2||(1/(jwC2))], where the ' ...
                'Q0/n branch is a Constant Phase Element capturing ' ...
                'non-ideal (depressed) diffusion/interfacial behaviour.'];
        end

        function paramNames = getParameterNames(~)
            paramNames = {'R3','R1','C1','Q0','n','r','R2','C2'};
        end

        function bounds = getParameterBounds(obj)
            bounds = struct( ...
                'R3', [0,     1e6], ...
                'R1', [1e-3,  1e6], ...
                'C1', [1e-12, 1e-1], ...
                'Q0', [1e-12, 1e-1], ...
                'n',  [0.3,   1.0], ...
                'r',  [1e-3,  1e5], ...
                'R2', [1e-3,  1e6], ...
                'C2', [1e-12, 1e-1]);
            bounds = obj.mergeUserBounds(bounds);
        end
    end

    % ------------------------------------------------------------------ %
    methods (Access = protected)
        function defaults = defaultParamValues(~)
            % [R3 R1 C1 Q0 n r R2 C2]
            defaults = [50, 500, 1e-6, 1e-6, 0.9, 100, 2000, 1e-6];
        end

        function units = paramUnits(~)
            units = {'Ohm','Ohm','F','F.s^(n-1)','-','Ohm','Ohm','F'};
        end
    end

    % ------------------------------------------------------------------ %
    methods (Static)
        function Z = circuitImpedance(w_vec, p, ~)
            %CIRCUITIMPEDANCE  Vectorised circuit evaluation.
            %  p = [R3, R1, C1, Q0, n, r, R2, C2]
            R3 = p(1); R1 = p(2); C1 = p(3); Q0 = p(4);
            n  = p(5); r  = p(6); R2 = p(7); C2 = p(8);

            w  = w_vec(:);
            jw = 1i * w;

            Z_C1  = 1 ./ (jw .* C1);
            Z_RC1 = (R1 .* Z_C1) ./ (R1 + Z_C1);   % R1 || 1/(jwC1)

            Z_C2  = 1 ./ (jw .* C2);
            Z_RC2 = (R2 .* Z_C2) ./ (R2 + Z_C2);   % R2 || 1/(jwC2)

            Z_Q0  = 1 ./ (Q0 .* jw.^n);            % CPE branch

            Z = R3 + Z_RC1 + Z_Q0 + r + Z_RC2;
        end
    end
end
