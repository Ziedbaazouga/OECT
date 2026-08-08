classdef ImpedanceSDModel < OECT.ImpedanceModel
    %OECT.IMPEDANCESDMODEL  Impedance (Source to Drain) EIS model.
    %
    %  Circuit topology (source-to-drain measurement). The device is a
    %  series parasitic resistance (Rs) followed by a Constant Phase
    %  Element (CPE_film) in parallel with a branch made of a resistor
    %  (Re) in series with an ideal capacitor (Cv):
    %
    %  Z = Rs + [CPE_film || (Re + Cv)]
    %
    %  The CPE_film in parallel with the (Re + Cv) branch bounds the
    %  low-frequency response and produces a depressed semicircular arc
    %  in the Nyquist plot, and a smooth "L-shaped" Bode response
    %  (flat-then-rolling-off magnitude, a single phase peak that
    %  returns toward 0 degrees).
    %
    %  Free parameters : Rs, Q, n, Re, Cv
    %
    %  The CPE_film (rather than an ideal capacitor) accounts for the
    %  dispersive, non-Debye film response commonly observed in
    %  source-to-drain EIS data, where the exponent n < 1 captures the
    %  depressed (non-ideal) frequency response, while Re and Cv model
    %  the electrolyte resistance and volumetric capacitance in series.

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
                'measurement. Circuit: Z = Rs + [CPE_film||(Re+Cv)], ' ...
                'a series parasitic resistance Rs followed by a ' ...
                'Constant Phase Element (CPE_film) capturing the ' ...
                'non-ideal (dispersive) film response, in parallel with ' ...
                'a resistor Re in series with an ideal capacitor Cv ' ...
                'modelling the electrolyte resistance and volumetric ' ...
                'capacitance. Matches data with a single depressed ' ...
                'semicircular Nyquist arc and a smooth, single-peak ' ...
                'Bode magnitude/phase profile.'];
        end

        function paramNames = getParameterNames(~)
            paramNames = {'Rs','Q','n','Re','Cv'};
        end

        function bounds = getParameterBounds(obj)
            bounds = struct( ...
                'Rs', [1e-3, 1e5], ...
                'Q',  [1e-12, 1e-1], ...
                'n',  [0.3,   1.0], ...
                'Re', [1e-3, 1e6], ...
                'Cv', [1e-12, 1e-1]);
            bounds = obj.mergeUserBounds(bounds);
        end
    end

    % ------------------------------------------------------------------ %
    methods (Access = protected)
        function defaults = defaultParamValues(~)
            % [Rs Q n Re Cv]
            defaults = [100, 1e-6, 0.9, 500, 1e-6];
        end

        function units = paramUnits(~)
            units = {'Ohm','F.s^(n-1)','-','Ohm','F'};
        end
    end

    % ------------------------------------------------------------------ %
    methods (Static)
        function Z = circuitImpedance(w_vec, p, ~)
            %CIRCUITIMPEDANCE  Vectorised circuit evaluation.
            %  p = [Rs, Q, n, Re, Cv]
            Rs = p(1); Q = p(2); n = p(3); Re = p(4); Cv = p(5);

            w  = w_vec(:);
            jw = 1i * w;

            Z_cpe    = 1 ./ (Q .* jw.^n);            % CPE_film
            Z_cv     = 1 ./ (jw .* Cv);               % ideal capacitor
            Z_branch = Re + Z_cv;                     % Re + Cv
            Z_par    = (Z_cpe .* Z_branch) ./ (Z_cpe + Z_branch); % CPE_film || (Re+Cv)

            Z = Rs + Z_par;
        end
    end
end
