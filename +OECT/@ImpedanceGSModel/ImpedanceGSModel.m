classdef ImpedanceGSModel < OECT.ImpedanceModel
    %OECT.IMPEDANCEGSMODEL  Impedance (GS shortcut) EIS model.
    %
    %  Circuit topology (gate-source shorted, 10 mM CaCl2). R1/R2 branches
    %  and the diffusion (Warburg-like) branch use Constant Phase Elements
    %  (CPE) rather than ideal capacitors, since real electrolyte/polymer
    %  interfaces produce depressed (non-ideal) arcs and a diffusion tail
    %  that is rarely at a perfect 45 degree angle:
    %
    %  Z = r + { [R2||(1/(Q2*(jw)^n2))] + [A/(jw)^nW] +
    %            [R1||(1/(Q1*(jw)^n1))] + R3 + r }  ||  [R0 + jwL0 + r]  +  Rload
    %
    %  Free parameters  : R0, L0, Q1, n1, R1, Q2, n2, R2, A, nW, r, R3
    %  Fixed parameters : Rload = 500 Ohm
    %
    %  n1, n2 are the CPE exponents of the two RC arcs (1 = ideal
    %  capacitor, <1 = depressed/tilted arc). nW is the CPE exponent of
    %  the diffusion branch (0.5 = ideal Warburg; deviations from 0.5
    %  rotate the low-frequency tail, matching non-ideal diffusion).
    %
    %  Multi-start fitting uses Latin-Hypercube Sampling (LHS) to generate
    %  initial guesses and fmincon (with GlobalSearch when available) to
    %  minimise a weighted complex-impedance residual.

    methods
        function obj = ImpedanceGSModel(parameters)
            if nargin < 1
                parameters = OECT.Parameters('Impedance_GS');
            end
            obj@OECT.ImpedanceModel(parameters);
        end

        % ----------------------------------------------------------------
        %  MODEL INTERFACE (required by OECT.Model / OECT.ImpedanceModel)
        % ----------------------------------------------------------------
        function name = getModelName(~)
            name = 'Impedance (GS shortcut)';
        end

        function description = getModelDescription(~)
            description = ['EIS impedance model for gate-source shorted OECT. ' ...
                'Circuit: Z = r + {[R2||(1/(Q2*(jw)^n2))] + [A/(jw)^nW] + ' ...
                '[R1||(1/(Q1*(jw)^n1))] + R3 + r} || [R0+jwL0+r] + Rload. ' ...
                'R1/R2 arcs and the diffusion branch use Constant Phase ' ...
                'Elements (CPE) to capture depressed/non-ideal (tilted) arcs.'];
        end

        function paramNames = getParameterNames(~)
            paramNames = {'R0','L0','Q1','n1','R1','Q2','n2','R2','A','nW','r','R3'};
        end

        function bounds = getParameterBounds(obj)
            bounds = struct( ...
                'R0',  [1e-3, 1e6], ...
                'L0',  [1e-12, 1e-1], ...
                'Q1',  [1e-12, 1e-1], ...
                'n1',  [0.3, 1.0], ...
                'R1',  [1e-3, 1e6], ...
                'Q2',  [1e-12, 1e-1], ...
                'n2',  [0.3, 1.0], ...
                'R2',  [1e-3, 1e6], ...
                'A',   [1e-6, 1e8], ...
                'nW',  [0.2, 0.8], ...
                'r',   [1e-3, 1e5], ...
                'R3',  [0, 1e6]);
            bounds = obj.mergeUserBounds(bounds);
        end
    end

    % ------------------------------------------------------------------ %
    methods (Access = protected)
        function defaults = defaultParamValues(~)
            % [R0 L0 Q1 n1 R1 Q2 n2 R2 A nW r R3]
            defaults = [1000, 1e-6, 1e-6, 0.9, 500, 1e-7, 0.9, 2000, 1e4, 0.5, 100, 50];
        end

        function units = paramUnits(~)
            units = {'Ohm','H','F.s^(n1-1)','-','Ohm','F.s^(n2-1)','-','Ohm','Ohm.s^-nW','-','Ohm','Ohm'};
        end
    end

    % ------------------------------------------------------------------ %
    methods (Static)
        function Z = circuitImpedance(w_vec, p, Rload)
            %CIRCUITIMPEDANCE  Vectorised circuit evaluation.
            %  p = [R0, L0, Q1, n1, R1, Q2, n2, R2, A, nW, r, R3]
            R0 = p(1); L0 = p(2); Q1 = p(3); n1 = p(4); R1 = p(5);
            Q2 = p(6); n2 = p(7); R2 = p(8); A  = p(9); nW = p(10);
            r  = p(11); R3 = p(12);

            w = w_vec(:);
            jw = 1i * w;

            Z_Q1  = 1 ./ (Q1 .* jw.^n1);           % CPE 1 (replaces ideal C1)
            Z_Q2  = 1 ./ (Q2 .* jw.^n2);           % CPE 2 (replaces ideal C2)
            Z_RC1 = (R1 .* Z_Q1) ./ (R1 + Z_Q1);   % R1 || CPE1
            Z_RC2 = (R2 .* Z_Q2) ./ (R2 + Z_Q2);   % R2 || CPE2
            Z_W   = A ./ jw.^nW;                    % generalised (non-ideal) Warburg/CPE

            Z_arm1 = Z_RC2 + Z_W + Z_RC1 + R3 + r; % ionic/channel arm
            Z_arm2 = R0 + 1i * w * L0 + r;          % inductive arm

            Z_par = (Z_arm1 .* Z_arm2) ./ (Z_arm1 + Z_arm2);
            Z = r + Z_par + Rload;
        end
    end
end
