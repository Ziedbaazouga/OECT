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

        function [lb, ub] = refineParameterBounds(~, paramNames, lb, ub, w_vec, Z_meas)
            %REFINEPARAMETERBOUNDS  Tighten the generic multi-decade bounds
            %  using the measured high-/low-frequency real-part asymptotes:
            %    - as w -> inf, the CPE_vol impedance -> 0, so
            %      Z -> Rs + Rchannel||Rpore  (upper bound for Rs)
            %    - as w -> 0, the CPE_vol impedance -> inf, so
            %      Z -> Rs + Rchannel          (gives Rchannel estimate)
            [Rs_est, Rchannel_est, Q_est] = OECT.ImpedanceSDModel.estimateAsymptotes(w_vec, Z_meas);
            if isnan(Rs_est), return; end

            [lb, ub] = OECT.ImpedanceSDModel.narrowBound(paramNames, lb, ub, 'Rs',       Rs_est,       0.1, 10);
            [lb, ub] = OECT.ImpedanceSDModel.narrowBound(paramNames, lb, ub, 'Rchannel', Rchannel_est, 0.1, 10);
            if ~isnan(Q_est)
                [lb, ub] = OECT.ImpedanceSDModel.narrowBound(paramNames, lb, ub, 'Q_vol', Q_est, 0.01, 100);
            end
        end

        function guesses = seedInitialGuesses(obj, paramNames, lb, ub, w_vec, Z_meas)
            %SEEDINITIALGUESSES  Add a data-driven guess (from the
            %  high-/low-frequency asymptotes) on top of the generic
            %  log-midpoint guess from the base class.
            baseGuess = seedInitialGuesses@OECT.ImpedanceModel(obj, paramNames, lb, ub, w_vec, Z_meas);

            [Rs_est, Rchannel_est, Q_est] = OECT.ImpedanceSDModel.estimateAsymptotes(w_vec, Z_meas);
            if isnan(Rs_est)
                guesses = baseGuess;
                return;
            end

            dataGuess = baseGuess;
            idxRs  = find(strcmp(paramNames, 'Rs'));
            idxRch = find(strcmp(paramNames, 'Rchannel'));
            idxQ   = find(strcmp(paramNames, 'Q_vol'));
            if ~isempty(idxRs),  dataGuess(idxRs)  = min(max(Rs_est,       lb(idxRs)),  ub(idxRs)); end
            if ~isempty(idxRch), dataGuess(idxRch) = min(max(Rchannel_est, lb(idxRch)), ub(idxRch)); end
            if ~isempty(idxQ) && ~isnan(Q_est)
                dataGuess(idxQ) = min(max(Q_est, lb(idxQ)), ub(idxQ));
            end

            guesses = [baseGuess; dataGuess];
        end
    end

    % ------------------------------------------------------------------ %
    methods (Static, Access = private)
        function [Rs_est, Rchannel_est, Q_est] = estimateAsymptotes(w_vec, Z_meas)
            %ESTIMATEASYMPTOTES  Rough Rs/Rchannel/Q_vol estimates from the
            %  measured data's high-/low-frequency behaviour. Returns NaN
            %  fields when there isn't enough valid data to estimate from.
            Rs_est = NaN; Rchannel_est = NaN; Q_est = NaN;

            w_vec = w_vec(:); Z_meas = Z_meas(:);
            valid = isfinite(w_vec) & w_vec > 0 & isfinite(real(Z_meas)) & isfinite(imag(Z_meas));
            if nnz(valid) < 2
                return;
            end
            w_vec = w_vec(valid); Z_meas = Z_meas(valid);

            [~, iMax] = max(w_vec);
            [~, iMin] = min(w_vec);

            Rs_est = max(real(Z_meas(iMax)), 1e-3);
            Rlf_est = real(Z_meas(iMin));
            Rchannel_est = max(Rlf_est - Rs_est, 1e-3);

            % Rough CPE magnitude estimate from the highest-frequency
            % imaginary part, assuming n ~ 1: |Im(Z)| ~ 1/(Q*w)
            ImZ = imag(Z_meas(iMax));
            if abs(ImZ) > eps
                Q_est = 1 / (w_vec(iMax) * abs(ImZ));
            end
        end

        function [lb, ub] = narrowBound(paramNames, lb, ub, name, estimate, loFactor, hiFactor)
            %NARROWBOUND  Shrink the [lb, ub] window for one named
            %  parameter toward [estimate*loFactor, estimate*hiFactor],
            %  intersected with the original bounds (never widening them,
            %  and always keeping lb < ub).
            idx = find(strcmp(paramNames, name));
            if isempty(idx) || ~isfinite(estimate) || estimate <= 0
                return;
            end
            newLb = max(lb(idx), estimate * loFactor);
            newUb = min(ub(idx), estimate * hiFactor);
            if newLb < newUb
                lb(idx) = newLb;
                ub(idx) = newUb;
            end
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
