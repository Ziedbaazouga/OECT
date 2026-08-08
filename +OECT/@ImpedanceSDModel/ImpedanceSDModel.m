classdef ImpedanceSDModel < OECT.ImpedanceModel
    %OECT.IMPEDANCESDMODEL  Impedance (Source to Drain) EIS model.
    %
    %  Circuit topology (source-to-drain measurement). The device is a
    %  series parasitic resistance (Rs) followed by a channel resistance
    %  (Rchannel) in parallel with a branch made of a pore resistance
    %  (Rpore) in series with a Constant Phase Element (CPE_vol):
    %
    %  Z = Rs + [Rchannel || (Rpore + 1/(Q_vol*(jw)^n))]
    %
    %  The Rchannel in parallel with the (Rpore + CPE_vol) branch bounds
    %  the low-frequency response and produces a depressed semicircular
    %  arc in the Nyquist plot, and a smooth "L-shaped" Bode response
    %  (flat-then-rolling-off magnitude, a single phase peak that
    %  returns toward 0 degrees).
    %
    %  Free parameters : Rs, Rchannel, Rpore, Q_vol, n
    %
    %  The CPE_vol (rather than an ideal capacitor) accounts for the
    %  dispersive, non-Debye volumetric response commonly observed in
    %  source-to-drain EIS data, where the exponent n < 1 captures the
    %  depressed (non-ideal) frequency response, while Rchannel and
    %  Rpore model the channel and pore resistances.

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
                'measurement. Circuit: Z = Rs + [Rchannel||(Rpore+' ...
                '1/(Q_vol*(jw)^n))], a series parasitic resistance Rs ' ...
                'followed by a channel resistance Rchannel in parallel ' ...
                'with a pore resistance Rpore in series with a ' ...
                'Constant Phase Element (CPE_vol) capturing the ' ...
                'non-ideal (dispersive) volumetric response. Matches ' ...
                'data with a single depressed semicircular Nyquist arc ' ...
                'and a smooth, single-peak Bode magnitude/phase profile.'];
        end

        function paramNames = getParameterNames(~)
            paramNames = {'Rs','Rchannel','Rpore','Q_vol','n'};
        end

        function bounds = getParameterBounds(obj)
            bounds = struct( ...
                'Rs',       [1e-3, 1e5], ...
                'Rchannel', [1e-3, 1e6], ...
                'Rpore',    [1e-3, 1e6], ...
                'Q_vol',    [1e-12, 1e-1], ...
                'n',        [0.3,   1.0]);
            bounds = obj.mergeUserBounds(bounds);
        end
    end

    % ------------------------------------------------------------------ %
    methods (Access = protected)
        function defaults = defaultParamValues(~)
            % [Rs Rchannel Rpore Q_vol n]
            defaults = [100, 500, 500, 1e-6, 0.9];
        end

        function units = paramUnits(~)
            units = {'Ohm','Ohm','Ohm','F.s^(n-1)','-'};
        end
    end

    % ------------------------------------------------------------------ %
    methods (Static)
        function Z = circuitImpedance(w_vec, p, ~)
            %CIRCUITIMPEDANCE  Vectorised circuit evaluation.
            %  p = [Rs, Rchannel, Rpore, Q_vol, n]
            Rs = p(1); Rchannel = p(2); Rpore = p(3); Q_vol = p(4); n = p(5);

            w  = w_vec(:);
            jw = 1i * w;

            Z_cpe    = 1 ./ (Q_vol .* jw.^n);              % CPE_vol
            Z_branch = Rpore + Z_cpe;                       % Rpore + CPE_vol
            Z_par    = (Rchannel .* Z_branch) ./ (Rchannel + Z_branch); % Rchannel || (Rpore+CPE_vol)

            Z = Rs + Z_par;
        end
    end
end
