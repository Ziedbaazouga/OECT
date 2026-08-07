classdef ImpedanceSDModel < OECT.ImpedanceModel
    %OECT.IMPEDANCESDMODEL  Impedance (Source to Drain) EIS model.
    %
    %  Circuit topology (source-to-drain measurement). The device is a
    %  series parasitic resistance (r) followed by a resistor R1 in
    %  parallel with a non-ideal double-layer capacitor modelled as a
    %  Constant Phase Element (CPE) Q1/n1:
    %
    %  Z = r + [R1 || (1/(Q1*(jw)^n1))]
    %
    %  A CPE alone in series with r traces a straight line in the Nyquist
    %  plane (a constant-phase spike), which does not match data showing a
    %  single, closed, semicircular arc. Placing R1 in parallel with the
    %  CPE bounds the low-frequency response at r + R1 and produces one
    %  depressed semicircular arc in the Nyquist plot, and a smooth
    %  "L-shaped" Bode response (flat-then-rolling-off magnitude, a single
    %  phase peak that returns toward 0 degrees) instead of a straight
    %  line.
    %
    %  Free parameters : r, R1, Q1, n1
    %
    %  The CPE (rather than an ideal capacitor) accounts for the
    %  dispersive, non-Debye roll-off commonly observed in source-to-drain
    %  EIS data, where the exponent n1 < 1 captures the depressed
    %  (non-ideal) frequency response.

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
                'measurement. Circuit: Z = r + [R1||(1/(Q1*(jw)^n1))], a ' ...
                'series parasitic resistance r followed by a resistor R1 ' ...
                'in parallel with a Constant Phase Element (CPE) ' ...
                'capturing the non-ideal (dispersive) double-layer ' ...
                'response. Matches data with a single depressed ' ...
                'semicircular Nyquist arc and a smooth, single-peak ' ...
                'Bode magnitude/phase profile.'];
        end

        function paramNames = getParameterNames(~)
            paramNames = {'r','R1','Q1','n1'};
        end

        function bounds = getParameterBounds(obj)
            bounds = struct( ...
                'r',  [1e-3, 1e5], ...
                'R1', [1e-3, 1e6], ...
                'Q1', [1e-12, 1e-1], ...
                'n1', [0.3,   1.0]);
            bounds = obj.mergeUserBounds(bounds);
        end
    end

    % ------------------------------------------------------------------ %
    methods (Access = protected)
        function defaults = defaultParamValues(~)
            % [r R1 Q1 n1]
            defaults = [100, 500, 1e-6, 0.9];
        end

        function units = paramUnits(~)
            units = {'Ohm','Ohm','F.s^(n1-1)','-'};
        end
    end

    % ------------------------------------------------------------------ %
    methods (Static)
        function Z = circuitImpedance(w_vec, p, ~)
            %CIRCUITIMPEDANCE  Vectorised circuit evaluation.
            %  p = [r, R1, Q1, n1]
            r = p(1); R1 = p(2); Q1 = p(3); n1 = p(4);

            w  = w_vec(:);
            jw = 1i * w;

            Z_cpe = 1 ./ (Q1 .* jw.^n1);           % CPE double-layer branch
            Z_par = (R1 .* Z_cpe) ./ (R1 + Z_cpe); % R1 || CPE

            Z = r + Z_par;
        end
    end
end
