classdef ImpedanceSDModel < OECT.ImpedanceModel
    %OECT.IMPEDANCESDMODEL  Impedance (Source to Drain) EIS model.
    %
    %  Circuit topology (source-to-drain measurement). The device is a
    %  series combination of a parasitic series resistance (r) and a
    %  non-ideal double-layer capacitor modelled as a Constant Phase
    %  Element (CPE) Q1/n1:
    %
    %  Z = r + 1/(Q1*(jw)^n1)
    %
    %  This single-dispersion topology matches source-to-drain EIS data
    %  that shows a monotonic |Z| roll-off and a phase angle that keeps
    %  decreasing (never turning back toward 0 degrees) across the whole
    %  measured band - i.e. no semicircular arc closes within the sweep,
    %  unlike a Randles-type R||CPE network whose high-frequency
    %  asymptote is pinned to a pure resistance (phase -> 0).
    %
    %  Free parameters : r, Q1, n1
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
                'measurement. Circuit: Z = r + 1/(Q1*(jw)^n1), a series ' ...
                'parasitic resistance r followed by a Constant Phase ' ...
                'Element (CPE) capturing the non-ideal (dispersive) ' ...
                'double-layer response. Matches data with a monotonic ' ...
                '|Z| roll-off and a phase that does not turn back toward ' ...
                '0 degrees within the measured band.'];
        end

        function paramNames = getParameterNames(~)
            paramNames = {'r','Q1','n1'};
        end

        function bounds = getParameterBounds(obj)
            bounds = struct( ...
                'r',  [1e-3, 1e5], ...
                'Q1', [1e-12, 1e-1], ...
                'n1', [0.3,   1.0]);
            bounds = obj.mergeUserBounds(bounds);
        end
    end

    % ------------------------------------------------------------------ %
    methods (Access = protected)
        function defaults = defaultParamValues(~)
            % [r Q1 n1]
            defaults = [100, 1e-6, 0.9];
        end

        function units = paramUnits(~)
            units = {'Ohm','F.s^(n1-1)','-'};
        end
    end

    % ------------------------------------------------------------------ %
    methods (Static)
        function Z = circuitImpedance(w_vec, p, ~)
            %CIRCUITIMPEDANCE  Vectorised circuit evaluation.
            %  p = [r, Q1, n1]
            r = p(1); Q1 = p(2); n1 = p(3);

            w  = w_vec(:);
            jw = 1i * w;

            Z_cpe = 1 ./ (Q1 .* jw.^n1);   % CPE double-layer branch

            Z = r + Z_cpe;
        end
    end
end
