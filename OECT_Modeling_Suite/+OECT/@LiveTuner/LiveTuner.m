classdef LiveTuner < handle
    %OECT.LIVETUNER Live parameter tuning with real-time feedback
    
    properties
        Model
        Figure
        Axes
        Sliders struct
        ParameterLabels struct
        CurrentResult
        UpdateOnChange logical = true
    end
    
    properties (Access = private)
        logger
        isUpdating logical = false
        pendingUpdate logical = false
    end
    
    methods
        function obj = LiveTuner(model)
            obj.Model = model;
            obj.logger = OECT.Logger('LiveTuner');
            obj.createUI();
            obj.initializeSliders();
        end
        
        function createUI(obj)
            obj.Figure = figure('Name', 'Live Parameter Tuner', ...
                'Position', [100, 100, 900, 700], ...
                'Color', [0.15, 0.15, 0.15], ...
                'NumberTitle', 'off', ...
                'MenuBar', 'none', ...
                'ToolBar', 'none');
            
            % Main layout
            mainLayout = uigridlayout(obj.Figure, [1, 2], ...
                'ColumnWidth', {'1x', '2x'}, ...
                'BackgroundColor', [0.15, 0.15, 0.15]);
            
            % Left panel - sliders
            leftPanel = uipanel(mainLayout, ...
                'Title', 'Parameters', ...
                'BackgroundColor', [0.2, 0.2, 0.2], ...
                'ForegroundColor', [1, 1, 1], ...
                'FontColor', [1, 1, 1], ...
                'FontWeight', 'bold');
            
            sliderLayout = uigridlayout(leftPanel, [10, 1], ...
                'RowHeight', repmat({35}, 1, 10), ...
                'BackgroundColor', [0.2, 0.2, 0.2]);
            
            % Right panel - plot
            rightPanel = uipanel(mainLayout, ...
                'Title', 'Simulation', ...
                'BackgroundColor', [0.2, 0.2, 0.2], ...
                'ForegroundColor', [1, 1, 1], ...
                'FontColor', [1, 1, 1], ...
                'FontWeight', 'bold');
            
            obj.Axes = uiaxes(rightPanel);
            obj.Axes.Color = [0.15, 0.15, 0.15];
            obj.Axes.XColor = [1, 1, 1];
            obj.Axes.YColor = [1, 1, 1];
            obj.Axes.GridColor = [0.3, 0.3, 0.3];
            obj.Axes.FontSize = 12;
            
            % Store slider references
            obj.Sliders = struct();
            obj.ParameterLabels = struct();
            
            % Create sliders for common parameters
            paramNames = obj.Model.getParameterNames();
            for i = 1:min(length(paramNames), 10)
                name = paramNames{i};
                obj.createSlider(sliderLayout, i, name);
            end
        end
        
        function createSlider(obj, layout, row, paramName)
            % Create a slider with label
            
            % Get bounds
            bounds = obj.Model.getParameterBounds();
            if isfield(bounds, paramName)
                minVal = bounds.(paramName)(1);
                maxVal = bounds.(paramName)(2);
            else
                minVal = 0;
                maxVal = 1;
            end
            
            % Get current value
            p = obj.Model.getParameters();
            if isfield(p.params, paramName)
                currentVal = p.params.(paramName);
            else
                currentVal = (minVal + maxVal) / 2;
            end
            
            % Create container
            container = uigridlayout(layout, [1, 3], ...
                'ColumnWidth', {'1x', '2x', '0.5x'});
            
            % Label
            label = uilabel(container, ...
                'Text', paramName, ...
                'FontColor', [1, 1, 1], ...
                'FontWeight', 'bold', ...
                'FontSize', 10);
            
            % Slider
            slider = uislider(container, ...
                'Limits', [minVal, maxVal], ...
                'Value', currentVal, ...
                'ValueChangedFcn', @(src, evt) obj.onSliderChange(paramName, src.Value), ...
                'BackgroundColor', [0.3, 0.3, 0.3]);
            
            % Value display
            valueLabel = uilabel(container, ...
                'Text', sprintf('%.2e', currentVal), ...
                'FontColor', [1, 1, 1], ...
                'FontSize', 10);
            
            obj.Sliders.(paramName) = slider;
            obj.ParameterLabels.(paramName) = valueLabel;
        end
        
        function initializeSliders(obj)
            % Set slider values from current model
            p = obj.Model.getParameters();
            paramNames = fieldnames(obj.Sliders);
            for i = 1:length(paramNames)
                name = paramNames{i};
                if isfield(p.params, name)
                    obj.Sliders.(name).Value = p.params.(name);
                    obj.ParameterLabels.(name).Text = sprintf('%.2e', p.params.(name));
                end
            end
        end
        
        function onSliderChange(obj, paramName, value)
            if obj.isUpdating
                obj.pendingUpdate = true;
                return;
            end
            
            obj.isUpdating = true;
            try
                % Update model parameter
                p = obj.Model.getParameters();
                p.setParameter(paramName, value);
                obj.Model.setParameters(p);
                
                % Update label
                if isfield(obj.ParameterLabels, paramName)
                    obj.ParameterLabels.(paramName).Text = sprintf('%.2e', value);
                end
                
                % Auto-update simulation
                if obj.UpdateOnChange
                    obj.updateSimulation();
                end
            catch ME
                obj.logger.error('Slider update failed: %s', ME.message);
            end
            obj.isUpdating = false;
            
            % Handle pending updates
            if obj.pendingUpdate
                obj.pendingUpdate = false;
                obj.updateSimulation();
            end
        end
        
        function updateSimulation(obj)
            % Update the simulation plot
            try
                % Get current parameters
                p = obj.Model.getParameters();
                
                % Run a simple simulation
                tau = obj.getTau();
                t = linspace(0, 10 * tau, 1000);
                Vg = -0.2 * ones(size(t));
                Vg(t > 5 * tau) = 0.2;
                Vds = -0.1;
                
                sim = obj.Model.simulate(Vg, t, Vds);
                
                % Update plot
                cla(obj.Axes);
                hold(obj.Axes, 'on');
                
                yyaxis(obj.Axes, 'left');
                plot(obj.Axes, sim.t * 1000, sim.Id * 1e3, 'LineWidth', 2, 'Color', [0, 0.7, 1]);
                ylabel(obj.Axes, 'I_d (mA)');
                
                yyaxis(obj.Axes, 'right');
                plot(obj.Axes, t * 1000, Vg, '--', 'LineWidth', 1.5, 'Color', [1, 0.6, 0]);
                ylabel(obj.Axes, 'V_g (V)');
                ylim(obj.Axes, [-0.3, 0.3]);
                
                xlabel(obj.Axes, 'Time (ms)');
                title(obj.Axes, 'Step Response (Live)');
                grid(obj.Axes, 'on');
                hold(obj.Axes, 'off');
                
            catch ME
                obj.logger.error('Simulation update failed: %s', ME.message);
            end
        end
        
        function tau = getTau(obj)
            p = obj.Model.getParameters();
            if isa(obj.Model, 'OECT.BisquertModel')
                tau = p.tau_de;
            elseif isa(obj.Model, 'OECT.ShirinskayaModel')
                tau = p.Cd * p.Rd * p.Rs / (p.Rd + p.Rs);
            else
                tau = 0.01;
            end
        end
        
        function updateParameters(obj, newParams)
            % Update all parameters at once
            if isa(newParams, 'OECT.Parameters')
                obj.Model.setParameters(newParams);
                obj.initializeSliders();
                obj.updateSimulation();
            end
        end
    end
end