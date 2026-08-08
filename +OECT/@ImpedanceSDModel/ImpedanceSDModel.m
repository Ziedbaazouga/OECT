classdef ImpedanceSDModel < OECT.ImpedanceModel
    %OECT.IMPEDANCESDMODEL  Impedance (Source to Drain) EIS model.
    %
    %  Circuit topology (source-to-drain measurement). The device is a
    %  series parasitic resistance (Rs) followed by an ideal double-layer
    %  capacitor (Cdl) in parallel with a branch made of a resistor (Rp)
    %  in series with a Constant Phase Element (CPE) Q/n:
    %
    %  Z = Rs + [Cdl || (Rp + (1/(Q*(jw)^n)))]
    %
    %  Cdl in parallel with the (Rp + CPE) branch bounds the low-frequency
    %  response and produces a depressed semicircular arc in the Nyquist
    %  plot, and a smooth "L-shaped" Bode response (flat-then-rolling-off
    %  magnitude, a single phase peak that returns toward 0 degrees).
    %
    %  Free parameters : Rs, Cdl, Rp, Q, n
    %
    %  The CPE (rather than an ideal capacitor) accounts for the
    %  dispersive, non-Debye roll-off commonly observed in source-to-drain
    %  EIS data, where the exponent n < 1 captures the depressed
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
                'measurement. Circuit: Z = Rs + [Cdl||(Rp+(1/(Q*(jw)^n)))], ' ...
                'a series parasitic resistance Rs followed by an ideal ' ...
                'double-layer capacitor Cdl in parallel with a resistor ' ...
                'Rp in series with a Constant Phase Element (CPE) ' ...
                'capturing the non-ideal (dispersive) interfacial ' ...
                'response. Matches data with a single depressed ' ...
                'semicircular Nyquist arc and a smooth, single-peak ' ...
                'Bode magnitude/phase profile.'];
        end

        function paramNames = getParameterNames(~)
            paramNames = {'Rs','Cdl','Rp','Q','n'};
        end

        function bounds = getParameterBounds(obj)
            bounds = struct( ...
                'Rs',  [1e-3, 1e5], ...
                'Cdl', [1e-12, 1e-1], ...
                'Rp',  [1e-3, 1e6], ...
                'Q',   [1e-12, 1e-1], ...
                'n',   [0.3,   1.0]);
            bounds = obj.mergeUserBounds(bounds);
        end
    end

    % ------------------------------------------------------------------ %
    methods (Access = protected)
        function defaults = defaultParamValues(~)
            % [Rs Cdl Rp Q n]
            defaults = [100, 1e-6, 500, 1e-6, 0.9];
        end

        function units = paramUnits(~)
            units = {'Ohm','F','Ohm','F.s^(n-1)','-'};
        end
    end

    % ------------------------------------------------------------------ %
    methods (Static)
        function Z = circuitImpedance(w_vec, p, ~)
            %CIRCUITIMPEDANCE  Vectorised circuit evaluation.
            %  p = [Rs, Cdl, Rp, Q, n]
            Rs = p(1); Cdl = p(2); Rp = p(3); Q = p(4); n = p(5);

            w  = w_vec(:);
            jw = 1i * w;

            Z_cdl    = 1 ./ (jw .* Cdl);             % ideal double-layer capacitor
            Z_cpe    = 1 ./ (Q .* jw.^n);            % CPE branch
            Z_branch = Rp + Z_cpe;                   % Rp + CPE
            Z_par    = (Z_cdl .* Z_branch) ./ (Z_cdl + Z_branch); % Cdl || (Rp + CPE)

            Z = Rs + Z_par;
        end
    end
end
