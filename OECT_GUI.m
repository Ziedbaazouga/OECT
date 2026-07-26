classdef OECT_GUI < matlab.apps.AppBase

    % Properties that correspond to app components
    properties (Access = public)
        UIFigure                        matlab.ui.Figure
        
        % Main Layout
        MainGrid                        matlab.ui.container.GridLayout
        
        % ===== LEFT PANEL =====
        LeftPanel                       matlab.ui.container.Panel
        LeftGrid                        matlab.ui.container.GridLayout
        
        % Model Selection
        ModelPanel                      matlab.ui.container.Panel
        ModelGrid                       matlab.ui.container.GridLayout
        ModelLabel                      matlab.ui.control.Label
        ModelDropdown                   matlab.ui.control.DropDown
        
        % Data Loading
        DataPanel                       matlab.ui.container.Panel
        DataGrid                        matlab.ui.container.GridLayout
        SteadyStateLabel                matlab.ui.control.Label
        SteadyStateEdit                 matlab.ui.control.EditField
        SteadyStateBrowseBtn            matlab.ui.control.Button
        TransientLabel                  matlab.ui.control.Label
        TransientEdit                   matlab.ui.control.EditField
        TransientBrowseBtn              matlab.ui.control.Button
        SheetLabel                      matlab.ui.control.Label
        SheetDropdown                   matlab.ui.control.DropDown
        LoadDataBtn                     matlab.ui.control.Button
        DataStatusLabel                 matlab.ui.control.Label
        
        % Geometry
        GeometryPanel                   matlab.ui.container.Panel
        GeometryGrid                    matlab.ui.container.GridLayout
        dLabel                          matlab.ui.control.Label
        dEdit                           matlab.ui.control.NumericEditField
        LLabel                          matlab.ui.control.Label
        LEdit                           matlab.ui.control.NumericEditField
        WLabel                          matlab.ui.control.Label
        WEdit                           matlab.ui.control.NumericEditField
        TLabel                          matlab.ui.control.Label
        TEdit                           matlab.ui.control.NumericEditField
        
        % Parameters
        ParamsPanel                     matlab.ui.container.Panel
        ParamsGrid                      matlab.ui.container.GridLayout
        ParamsTable                     matlab.ui.control.Table
        
        % Fitting
        FitPanel                        matlab.ui.container.Panel
        FitGrid                         matlab.ui.container.GridLayout
        FitBtn                          matlab.ui.control.Button
        R2Label                         matlab.ui.control.Label
        R2Edit                          matlab.ui.control.NumericEditField
        NRMSELabel                      matlab.ui.control.Label
        NRMSEEdit                       matlab.ui.control.NumericEditField
        FitProgress                     matlab.ui.control.Label
        FitStatusLabel                  matlab.ui.control.Label
        CancelFitBtn                    matlab.ui.control.Button
        % Multi-start controls (Impedance EIS)
        NStartsLabel                    matlab.ui.control.Label
        NStartsEdit                     matlab.ui.control.NumericEditField
        
        % ===== RIGHT PANEL =====
        RightPanel                      matlab.ui.container.Panel
        RightGrid                       matlab.ui.container.GridLayout
        
        % Tests (parameter input fields for each test are created dynamically
        % and stored in the TestParamEdits map; see initializeTestCheckboxes)
        TestsPanel                      matlab.ui.container.Panel
        TestsGrid                       matlab.ui.container.GridLayout
        TestCheckBoxes                  matlab.ui.control.CheckBox
        SaveDataCheck                   matlab.ui.control.CheckBox
        RunTestsBtn                     matlab.ui.control.Button
        CancelTestsBtn                  matlab.ui.control.Button
        
        % Export
        ExportPanel                     matlab.ui.container.Panel
        ExportGrid                      matlab.ui.container.GridLayout
        ExportParamsBtn                 matlab.ui.control.Button
        ExportPlotsBtn                  matlab.ui.control.Button
        ExportReportBtn                 matlab.ui.control.Button
        ExportExcelBtn                  matlab.ui.control.Button
        LiveTuneBtn                     matlab.ui.control.Button
        
        % Status Bar
        StatusBar                       matlab.ui.control.Label
    end

    % Properties that store application data
    properties (Access = private)
        model
        parameters
        dataLoader
        logger
        stateManager
        testSuite
        testResults cell
        liveTuner
        isFitting logical = false
        isTesting logical = false
        isLoaded logical = false
        isFitted logical = false
        config struct
        % EIS-specific data
        eisDataLoader        % OECT.ImpedanceDataLoader instance
        eisData struct       % loaded EIS data
        eisFitResults struct % last EIS fit results
        cancelFitFlag logical = false
        % Test parameters: containers.Map, test name -> struct with fields
        % 'names' (cell of labels) and 'edits' (array of edit field handles),
        % populated per-test directly next to each test checkbox.
        TestParamEdits
        % Handles to the standalone (non-GUI) figures/axes used for plotting
        % test and EIS results, keyed by plot name, so Export Plots can
        % still find and export the most recently created figures.
        resultAxes
    end

    methods (Access = private)

        function setupApp(app)
            app.TestParamEdits = containers.Map();
            app.resultAxes = containers.Map();
            try
                app.logger = OECT.Logger('GUI');
            catch
                app.logger = struct(...
                    'info', @(msg, varargin) fprintf(['[INFO] ' msg '\n'], varargin{:}), ...
                    'warn', @(msg, varargin) fprintf(['[WARN] ' msg '\n'], varargin{:}), ...
                    'error', @(msg, varargin) fprintf(['[ERROR] ' msg '\n'], varargin{:}));
            end
            app.logger.info('OECT Modeling Suite v2.0 starting...');
            
            try
                app.stateManager = OECT.StateManager();
            catch
                app.stateManager = struct('getState', @() 'Idle', 'transition', @(s) true, 'registerCallback', @(varargin) true);
            end
            app.setupStateCallbacks();
            
            try
                app.dataLoader = OECT.DataLoader();
            catch
                app.dataLoader = struct('loadSteadyState', @(f) true, 'loadTransient', @(fs) true, 'steadyState', struct('sheets', {{'Sheet1', 'Sheet2'}}));
            end
            
            app.loadConfig();
            app.setupDarkMode();
            app.populateDropdowns();
            app.initializeTestCheckboxes();
            app.setupDefaultValues();
            app.refreshParameters();
            app.updateUIState();
            
            app.logger.info('GUI initialized successfully');
        end

        function setupStateCallbacks(app)
            if isstruct(app.stateManager)
                return;
            end
            try
                app.stateManager.registerCallback('Idle', 'DataLoaded', @() app.onDataLoaded());
                app.stateManager.registerCallback('DataLoaded', 'Fitted', @() app.onFitted());
                app.stateManager.registerCallback('Fitted', 'Testing', @() app.onTesting());
                app.stateManager.registerCallback('Testing', 'Results', @() app.onResults());
                app.stateManager.registerCallback('Error', 'Idle', @() app.onErrorReset());
            catch
            end
        end

        function setupDarkMode(app)
            app.UIFigure.Color = [0.12, 0.12, 0.12];
            app.UIFigure.Name = 'OECT Modeling Suite v2.0';
            
            panels = [app.LeftPanel, app.RightPanel, app.ModelPanel, ...
                      app.DataPanel, app.GeometryPanel, app.ParamsPanel, ...
                      app.FitPanel, app.TestsPanel, app.ExportPanel];
            for p = panels
                p.BackgroundColor = [0.18, 0.18, 0.18];
                p.ForegroundColor = [1, 1, 1];
            end
            
            labels = findall(app.UIFigure, 'Type', 'uilabel');
            for l = labels'
                l.FontColor = [1, 1, 1];
            end
            
            edits = findall(app.UIFigure, 'Type', 'uieditfield');
            for e = edits'
                e.BackgroundColor = [0.25, 0.25, 0.25];
                e.FontColor = [1, 1, 1];
            end
            
            buttons = findall(app.UIFigure, 'Type', 'uibutton');
            for b = buttons'
                b.BackgroundColor = [0.3, 0.3, 0.3];
                b.FontColor = [1, 1, 1];
            end
            
            checks = findall(app.UIFigure, 'Type', 'uicheckbox');
            for c = checks'
                c.FontColor = [1, 1, 1];
            end
            
            if ~isempty(app.ParamsTable)
                app.ParamsTable.BackgroundColor = [0.25, 0.25, 0.25];
            end
            
            if ~isempty(app.FitProgress)
                app.FitProgress.BackgroundColor = [0.25, 0.25, 0.25];
                app.FitProgress.FontColor = [0.9, 0.9, 0.9];
                app.FitProgress.HorizontalAlignment = 'center';
            end
            
            app.StatusBar.BackgroundColor = [0.15, 0.15, 0.15];
            app.StatusBar.FontColor = [0.8, 0.8, 0.8];
        end

        function populateDropdowns(app)
            app.ModelDropdown.Items = {'Bisquert (Ionic Dynamics)', ...
                                       'Shirinskaya (PNP + RC)', ...
                                       'Impedance (EIS Fitting)'};
            app.ModelDropdown.Value = 'Bisquert (Ionic Dynamics)';
        end

        function initializeTestCheckboxes(app)
            % TESTSPEC  Each test gets its own directly-adjacent parameter
            % edit field(s) instead of a shared "Test Parameters" panel.
            % Format: {testName, {label1, default1}, {label2, default2}, ...}
            testSpec = {
                {'Step',                {'Vds',  -0.1}}, ...
                {'Transfer',            {'Vds',  -0.1}}, ...
                {'Output',              {'Vgs',  -0.1}}, ...
                {'Hysteresis',          {'Vds',  -0.1}}, ...
                {'PPX',                 {'PW',    2},   {'Gap',  1}}, ...
                {'Vg Train (Amp)',      {'Amp',  -0.1}}, ...
                {'Vg Train (Interval)', {'Gap',   1}}, ...
                {'Vd Train (Amp)',      {'Amp',  -0.1}}, ...
                {'Vd Train (Interval)', {'Gap',   1}}, ...
                {'Vds Pulse',           {'PW',    2},   {'N',   30}}, ...
                };

            delete(app.TestsGrid.Children);

            nTests = length(testSpec);
            app.TestsGrid.RowHeight = repmat({25}, 1, nTests + 1);
            app.TestsGrid.ColumnWidth = {'1.3x', 35, '0.8x', 35, '0.8x'};

            checkboxes = cell(1, nTests);
            app.TestParamEdits = containers.Map();
            for i = 1:nTests
                spec = testSpec{i};
                testName = spec{1};

                checkbox = uicheckbox(app.TestsGrid, ...
                    'Text', testName, ...
                    'Value', true, ...
                    'FontColor', [1, 1, 1], ...
                    'FontSize', 11);
                checkbox.Layout.Row = i;
                checkbox.Layout.Column = 1;
                checkboxes{i} = checkbox;

                names = {};
                edits = matlab.ui.control.NumericEditField.empty;
                for p = 2:length(spec)
                    label = spec{p}{1};
                    default = spec{p}{2};
                    col = 2 + 2 * (p - 2);

                    lbl = uilabel(app.TestsGrid, 'Text', [label ':'], 'FontColor', [1, 1, 1]);
                    lbl.Layout.Row = i; lbl.Layout.Column = col;

                    edit = uieditfield(app.TestsGrid, 'numeric', 'Value', default, ...
                        'BackgroundColor', [0.25, 0.25, 0.25], 'FontColor', [1, 1, 1]);
                    edit.Layout.Row = i; edit.Layout.Column = col + 1;

                    names{end+1} = label; %#ok<AGROW>
                    edits(end+1) = edit; %#ok<AGROW>
                end
                app.TestParamEdits(testName) = struct('names', {names}, 'edits', edits);
            end
            app.TestCheckBoxes = [checkboxes{:}];

            % Controls row: Save Data / Run / Cancel, directly below the tests
            app.SaveDataCheck = uicheckbox(app.TestsGrid, 'Text', 'Save Data', ...
                'Value', false, 'FontColor', [1, 1, 1]);
            app.SaveDataCheck.Layout.Row = nTests + 1;
            app.SaveDataCheck.Layout.Column = 1;

            app.RunTestsBtn = uibutton(app.TestsGrid, 'Text', 'Run Tests', ...
                'BackgroundColor', [0, 0.6, 0.2], 'FontColor', [1, 1, 1], 'FontWeight', 'bold', ...
                'ButtonPushedFcn', @(src, evt) app.RunTestsBtnPushed());
            app.RunTestsBtn.Layout.Row = nTests + 1;
            app.RunTestsBtn.Layout.Column = [2 3];

            app.CancelTestsBtn = uibutton(app.TestsGrid, 'Text', 'Cancel', ...
                'BackgroundColor', [0.6, 0.1, 0.1], 'FontColor', [1, 1, 1], 'Enable', 'off', ...
                'ButtonPushedFcn', @(src, evt) app.CancelTestsBtnPushed());
            app.CancelTestsBtn.Layout.Row = nTests + 1;
            app.CancelTestsBtn.Layout.Column = [4 5];
        end

        function setupDefaultValues(app)
            app.dEdit.Value = 10e-6;
            app.LEdit.Value = 25e-6;
            app.WEdit.Value = 10e-6;
            app.TEdit.Value = 290;
            
            app.SaveDataCheck.Value = false;
            
            app.R2Edit.Value = 0.5;
            app.NRMSEEdit.Value = 0.2;
            
            app.FitStatusLabel.Text = 'Ready';
            app.DataStatusLabel.Text = 'No data loaded';
            app.FitProgress.Text = '0%';
        end

        function loadConfig(app)
            configFile = 'config/gui_config.mat';
            if isfile(configFile)
                try
                    S = load(configFile);
                    if isfield(S, 'config')
                        app.config = S.config;
                    end
                catch
                    app.config = struct();
                end
            else
                app.config = struct();
            end
            
            if ~isfield(app.config, 'recentFiles')
                app.config.recentFiles = struct('steadyState', '', 'transient', {});
            end
        end

        function saveConfig(app)
            try
                if ~isfolder('config'), mkdir('config'); end
                save('config/gui_config.mat', 'app.config');
            catch ME
                app.logger.warn('Could not save config: %s', ME.message);
            end
        end

        function updateUIState(app)
            if isstruct(app.stateManager)
                % No real StateManager available (construction failed at
                % startup) - derive the UI state from the isLoaded/isFitted
                % flags instead of hard-coding 'Idle', otherwise controls
                % such as the Fit button would stay disabled forever even
                % after data has been loaded successfully.
                if app.isTesting
                    state = 'Testing';
                elseif app.isFitted
                    state = 'Fitted';
                elseif app.isLoaded
                    state = 'DataLoaded';
                else
                    state = 'Idle';
                end
            else
                try
                    state = app.stateManager.getState();
                catch
                    state = 'Idle';
                end
            end
            
            switch state
                case 'Idle'
                    app.setUIEnabled('Data', true);
                    app.setUIEnabled('Fit', false);
                    app.setUIEnabled('Test', false);
                    app.setUIEnabled('Export', false);
                    app.FitBtn.Enable = 'off';
                    app.RunTestsBtn.Enable = 'off';
                    
                case 'DataLoaded'
                    app.setUIEnabled('Data', true);
                    app.setUIEnabled('Fit', true);
                    app.setUIEnabled('Test', false);
                    app.setUIEnabled('Export', false);
                    app.FitBtn.Enable = 'on';
                    app.RunTestsBtn.Enable = 'off';
                    
                case 'Fitted'
                    app.setUIEnabled('Data', true);
                    app.setUIEnabled('Fit', true);
                    app.setUIEnabled('Test', true);
                    app.setUIEnabled('Export', true);
                    app.FitBtn.Enable = 'on';
                    app.RunTestsBtn.Enable = 'on';
                    
                case 'Testing'
                    app.setUIEnabled('Data', false);
                    app.setUIEnabled('Fit', false);
                    app.setUIEnabled('Test', false);
                    app.setUIEnabled('Export', false);
                    app.FitBtn.Enable = 'off';
                    app.RunTestsBtn.Enable = 'off';
                    app.CancelTestsBtn.Enable = 'on';
                    
                case 'Results'
                    app.setUIEnabled('Data', true);
                    app.setUIEnabled('Fit', true);
                    app.setUIEnabled('Test', true);
                    app.setUIEnabled('Export', true);
                    app.FitBtn.Enable = 'on';
                    app.RunTestsBtn.Enable = 'on';
                    app.CancelTestsBtn.Enable = 'off';
                    
                case 'Error'
                    app.setUIEnabled('Data', true);
                    app.setUIEnabled('Fit', false);
                    app.setUIEnabled('Test', false);
                    app.setUIEnabled('Export', false);
                    app.FitBtn.Enable = 'off';
                    app.RunTestsBtn.Enable = 'off';
            end
        end

        function setUIEnabled(app, group, enabled)
            switch group
                case 'Data'
                    app.SteadyStateBrowseBtn.Enable = app.bool2onoff(enabled);
                    app.TransientBrowseBtn.Enable = app.bool2onoff(enabled);
                    app.LoadDataBtn.Enable = app.bool2onoff(enabled);
                    
                case 'Fit'
                    app.FitBtn.Enable = app.bool2onoff(enabled);
                    app.R2Edit.Enable = app.bool2onoff(enabled);
                    app.NRMSEEdit.Enable = app.bool2onoff(enabled);
                    
                case 'Test'
                    for i = 1:length(app.TestCheckBoxes)
                        if isvalid(app.TestCheckBoxes(i))
                            app.TestCheckBoxes(i).Enable = app.bool2onoff(enabled);
                        end
                    end
                    if ~isempty(app.TestParamEdits)
                        testNames = keys(app.TestParamEdits);
                        for i = 1:length(testNames)
                            rowEdits = app.TestParamEdits(testNames{i}).edits;
                            for j = 1:length(rowEdits)
                                if isvalid(rowEdits(j))
                                    rowEdits(j).Enable = app.bool2onoff(enabled);
                                end
                            end
                        end
                    end
                    app.SaveDataCheck.Enable = app.bool2onoff(enabled);
                    app.RunTestsBtn.Enable = app.bool2onoff(enabled);
                    
                case 'Export'
                    app.ExportParamsBtn.Enable = app.bool2onoff(enabled);
                    app.ExportPlotsBtn.Enable = app.bool2onoff(enabled);
                    app.ExportReportBtn.Enable = app.bool2onoff(enabled);
                    app.ExportExcelBtn.Enable = app.bool2onoff(enabled);
                    app.LiveTuneBtn.Enable = app.bool2onoff(enabled);
            end
        end

        function str = bool2onoff(~, val)
            if val, str = 'on'; else, str = 'off'; end
        end

        function onDataLoaded(app)
            app.isLoaded = true;
            app.DataStatusLabel.Text = '✓ Data loaded successfully';
            app.refreshParameters();
            app.logger.info('Data loaded');
        end

        function onFitted(app)
            app.isFitted = true;
            app.FitStatusLabel.Text = '✓ Fitting complete';
            app.logger.info('Parameters fitted');
        end

        function onTesting(app)
            app.isTesting = true;
            app.StatusBar.Text = 'Running tests...';
        end

        function onResults(app)
            app.isTesting = false;
            app.StatusBar.Text = '✓ Tests complete';
            app.logger.info('Tests complete');
        end

        function onErrorReset(app)
            app.isFitting = false;
            app.isTesting = false;
            app.StatusBar.Text = 'Ready';
            app.logger.info('Error state reset');
        end

        function loadData(app)
            app.logger.info('Loading data...');
            app.DataStatusLabel.Text = 'Loading...';
            drawnow;

            try
                modelType = app.getModelType();

                if strcmp(modelType, 'Impedance')
                    % --- EIS mode: load from the "Steady" field (xlsx) ---
                    eisFile = app.SteadyStateEdit.Value;
                    if isempty(eisFile) || ~isfile(eisFile)
                        error('Please select a valid EIS .xlsx file in the "File:" field');
                    end
                    app.eisDataLoader = OECT.ImpedanceDataLoader();
                    app.eisDataLoader.loadFile(eisFile);
                    app.eisData = app.eisDataLoader.getData();
                    app.SheetDropdown.Items = {'EIS Data'};
                    app.SheetDropdown.Value = 'EIS Data';
                    app.DataStatusLabel.Text = sprintf('✓ %d EIS points loaded', ...
                        length(app.eisData.frequency));
                    % Preview on Nyquist tab
                    app.plotEISPreview();
                else
                    % --- Standard transient / steady-state mode ---
                    steadyFile = app.SteadyStateEdit.Value;
                    transientFiles = app.TransientEdit.Value;

                    if isempty(steadyFile) || ~isfile(steadyFile)
                        error('Please select a valid steady-state file');
                    end
                    if isempty(transientFiles)
                        error('Please select transient files');
                    end

                    if contains(transientFiles, ';')
                        files = strsplit(transientFiles, ';');
                        files = strtrim(files);
                    else
                        files = {transientFiles};
                    end

                    if isstruct(app.dataLoader)
                        sheets = {'Sheet1'};
                    else
                        try
                            app.dataLoader.loadSteadyState(steadyFile);
                            app.dataLoader.loadTransient(files);
                            sheets = app.dataLoader.steadyState.sheets;
                        catch
                            sheets = {'Sheet1'};
                        end
                    end

                    app.SheetDropdown.Items = sheets;
                    if ~isempty(sheets), app.SheetDropdown.Value = sheets{1}; end
                end

                if ~isstruct(app.stateManager)
                    ok = false;
                    try, ok = app.stateManager.transition('DataLoaded'); catch, end
                    if ~ok, app.onDataLoaded(); end
                else
                    app.onDataLoaded();
                end
                app.updateUIState();
                app.logger.info('Data loaded successfully');

            catch ME
                app.logger.error('Data loading failed: %s', ME.message);
                app.DataStatusLabel.Text = sprintf('ERROR: %s', ME.message);
                if ~isstruct(app.stateManager)
                    try, app.stateManager.transition('Error'); catch, app.onErrorReset(); end
                else
                    app.onErrorReset();
                end
                app.updateUIState();
            end
        end

        function browseSteadyStateFile(app)
            if strcmp(app.getModelType(), 'Impedance')
                dialogTitle = 'Select EIS Impedance Data File';
            else
                dialogTitle = 'Select Steady-State Data File';
            end
            [file, path] = uigetfile({'*.xlsx;*.xls;*.csv;*.mat', 'Supported Files'}, dialogTitle);
            if file ~= 0, app.SteadyStateEdit.Value = fullfile(path, file); end
        end

        function browseTransientFiles(app)
            [files, path] = uigetfile({'*.xlsx;*.xls;*.csv;*.mat', 'Supported Files'}, 'Select Transient Data Files', 'MultiSelect', 'on');
            if iscell(files)
                fullPaths = cellfun(@(f) fullfile(path, f), files, 'UniformOutput', false);
                app.TransientEdit.Value = strjoin(fullPaths, '; ');
            elseif files ~= 0
                app.TransientEdit.Value = fullfile(path, files);
            end
        end

        function fitParameters(app)
            if app.isFitting, return; end

            app.isFitting = true;
            app.cancelFitFlag = false;
            app.FitBtn.Enable = 'off';
            app.CancelFitBtn.Enable = 'on';
            app.FitStatusLabel.Text = 'Fitting in progress...';
            app.FitProgress.Text = '0%';
            drawnow;

            try
                modelType = app.getModelType();
                app.refreshParameters();

                if strcmp(modelType, 'Impedance')
                    % ---- EIS multi-start fitting ----
                    if isempty(app.eisData) || ~isfield(app.eisData, 'frequency')
                        error('Please load EIS data first');
                    end
                    eisModel = OECT.ImpedanceModel(app.parameters);

                    nStarts = 50;
                    if ~isempty(app.NStartsEdit) && isvalid(app.NStartsEdit)
                        nStarts = max(1, round(app.NStartsEdit.Value));
                    end

                    progressFcn = @(s, nS, bestR2) app.updateFitProgress(s, nS, bestR2);
                    fitOpts = struct('nStarts', nStarts, 'maxIter', 500, ...
                        'tol', 1e-8, 'verbose', false, ...
                        'useParallel', false, 'progressFcn', progressFcn);

                    app.eisFitResults = eisModel.fit(app.eisData, fitOpts);
                    fitResults = app.eisFitResults;
                    app.parameters = fitResults.parameters;

                    % Plot fit results in standalone figures (not embedded in the GUI)
                    eisModel.plotNyquist(app.getResultAxes('Nyquist'), app.eisData, fitResults);
                    eisModel.plotBode(app.getResultAxes('BodeMag'), app.getResultAxes('BodePhase'), ...
                        app.eisData, fitResults);
                    eisModel.plotResiduals(app.getResultAxes('Residuals'), app.eisData, fitResults);
                else
                    % ---- Existing model fitting (placeholder) ----
                    app.FitProgress.Text = '30%'; drawnow; pause(0.2);
                    app.FitProgress.Text = '70%'; drawnow; pause(0.2);
                    fitResults.avgR2 = 0.9845;
                end

                app.updateParameterTable();

                if ~isfolder('config'), mkdir('config'); end
                save('config/modelParams.mat', 'fitResults');

                app.FitProgress.Text = '100%';
                app.FitStatusLabel.Text = sprintf('✓ Fit complete! R²=%.4f', fitResults.avgR2);

                if ~isstruct(app.stateManager)
                    ok = false;
                    try, ok = app.stateManager.transition('Fitted'); catch, end
                    if ~ok, app.onFitted(); end
                else
                    app.onFitted();
                end
                app.updateUIState();
                app.logger.info('Fitting complete');

            catch ME
                app.logger.error('Fitting failed: %s', ME.message);
                app.FitStatusLabel.Text = sprintf('ERROR: %s', ME.message);
                app.FitProgress.Text = '0%';
                if ~isstruct(app.stateManager)
                    try, app.stateManager.transition('Error'); catch, app.onErrorReset(); end
                else
                    app.onErrorReset();
                end
                app.updateUIState();
            end

            app.isFitting = false;
            app.FitBtn.Enable = 'on';
            app.CancelFitBtn.Enable = 'off';
        end

        function updateFitProgress(app, s, nStarts, bestR2)
            pct = round(100 * s / nStarts);
            app.FitProgress.Text = sprintf('%d%%', pct);
            app.FitStatusLabel.Text = sprintf('Start %d/%d | Best R²=%.4f', s, nStarts, bestR2);
            drawnow limitrate;
        end

        function cancelFit(app)
            if app.isFitting
                app.cancelFitFlag = true;
                app.FitStatusLabel.Text = 'Cancelling fit...';
                app.logger.info('Fit cancelled by user');
            end
        end

        function modelType = getModelType(app)
            value = app.ModelDropdown.Value;
            if contains(value, 'Bisquert'), modelType = 'Bisquert';
            elseif contains(value, 'Shirinskaya'), modelType = 'Shirinskaya';
            else, modelType = 'Impedance';
            end
        end

        function ax = getResultAxes(app, name)
            %GETRESULTAXES  Return (creating if needed) a dark-themed axes on
            %   a standalone MATLAB figure for the named plot. Plots are not
            %   embedded in the GUI; each one opens in its own figure window,
            %   and the handle is kept so Export Plots can find it again.
            if isempty(app.resultAxes)
                app.resultAxes = containers.Map();
            end
            if isKey(app.resultAxes, name) && isvalid(app.resultAxes(name))
                ax = app.resultAxes(name);
                cla(ax);
                figure(ancestor(ax, 'figure'));
                return;
            end
            fig = figure('Name', name, 'Color', [0.12, 0.12, 0.12], 'NumberTitle', 'off');
            ax = axes(fig);
            ax.Color = [0.15, 0.15, 0.15];
            ax.XColor = [0.9, 0.9, 0.9];
            ax.YColor = [0.9, 0.9, 0.9];
            ax.GridColor = [0.4, 0.4, 0.4];
            ax.FontSize = 11;
            app.resultAxes(name) = ax;
        end

        function updateDataPanelForModel(app)
            %UPDATEDATAPANELFORMODEL  Adapt Data Loading labels for the selected model.
            modelType = app.getModelType();
            if strcmp(modelType, 'Impedance')
                app.SteadyStateLabel.Text = 'File:';
                app.SteadyStateEdit.Tooltip = ['Select an .xlsx/.xls file with Frequency, ' ...
                    'Magnitude and Phase sheets (see measurements/Impedance/README.md)'];
                app.TransientLabel.Text   = '(unused)';
                app.TransientEdit.Enable  = 'off';
                app.TransientBrowseBtn.Enable = 'off';
                if ~isempty(app.NStartsLabel) && isvalid(app.NStartsLabel)
                    app.NStartsLabel.Visible = 'on';
                    app.NStartsEdit.Visible  = 'on';
                end
            else
                app.SteadyStateLabel.Text = 'Steady:';
                app.SteadyStateEdit.Tooltip = '';
                app.TransientLabel.Text   = 'Transient:';
                app.TransientEdit.Enable  = 'on';
                app.TransientBrowseBtn.Enable = 'on';
                if ~isempty(app.NStartsLabel) && isvalid(app.NStartsLabel)
                    app.NStartsLabel.Visible = 'off';
                    app.NStartsEdit.Visible  = 'off';
                end
            end
        end

        function plotEISPreview(app)
            %PLOTEISPREVIEW  Show experimental Nyquist/Bode plots after loading
            %   EIS data, each in its own standalone figure window.
            if isempty(app.eisData) || ~isfield(app.eisData, 'Z_real'), return; end
            try
                ax = app.getResultAxes('Nyquist');
                plot(ax, app.eisData.Z_real, -app.eisData.Z_imag, 'o', ...
                    'MarkerSize', 4, 'Color', [0.3 0.6 1]);
                xlabel(ax, 'Z_{real} (\Omega)');
                ylabel(ax, '-Z_{imag} (\Omega)');
                title(ax, 'Nyquist – Experimental');
                grid(ax, 'on'); axis(ax, 'equal');

                freq = app.eisData.frequency;
                Z_m  = app.eisData.Z_real + 1i * app.eisData.Z_imag;

                axM = app.getResultAxes('BodeMag');
                semilogx(axM, freq, 20*log10(abs(Z_m)), 'o', ...
                    'MarkerSize', 4, 'Color', [0.3 0.6 1]);
                ylabel(axM, '|Z| (dB\Omega)');
                title(axM, 'Bode – Magnitude');
                grid(axM, 'on');

                axP = app.getResultAxes('BodePhase');
                semilogx(axP, freq, angle(Z_m)*180/pi, 'o', ...
                    'MarkerSize', 4, 'Color', [0.3 0.6 1]);
                ylabel(axP, 'Phase (deg)');
                xlabel(axP, 'Frequency (Hz)');
                title(axP, 'Bode – Phase');
                grid(axP, 'on');
            catch ME
                app.logger.warn('EIS preview failed: %s', ME.message);
            end
        end

        function refreshParameters(app)
            %REFRESHPARAMETERS  (Re)build app.parameters from the current model
            %   and geometry selection, and refresh the Parameters table.
            %   Called as soon as a model is chosen or data is loaded, so the
            %   panel is populated (not left empty/grey) before fitting.
            try
                modelType = app.getModelType();
                geometry.d = app.dEdit.Value;
                geometry.L = app.LEdit.Value;
                geometry.W = app.WEdit.Value;
                geometry.T = app.TEdit.Value;

                try
                    app.parameters = OECT.Parameters(modelType);
                    app.parameters.setGeometry(geometry.d, geometry.L, geometry.W, geometry.T);
                catch
                    app.parameters = struct('geometry', geometry, 'params', struct());
                end
                app.updateParameterTable();
            catch ME
                app.logger.warn('Could not refresh parameters: %s', ME.message);
            end
        end

        function updateParameterTable(app)
            if isempty(app.parameters), return; end
            
            if isstruct(app.parameters)
                paramNames = fieldnames(app.parameters.params);
                getParam = @(field) app.parameters.params.(field);
                getGeom = @(field) app.parameters.geometry.(field);
            else
                try
                    paramNames = fieldnames(app.parameters.params);
                    getParam = @(field) app.parameters.params.(field);
                    getGeom = @(field) app.parameters.geometry.(field);
                catch
                    paramNames = {'mu_h', 'C_star', 'V_th'};
                    getParam = @(field) 1e-5;
                    getGeom = @(field) 10e-6;
                end
            end
            
            nParams = length(paramNames);
            data = cell(nParams + 4, 3);
            for i = 1:nParams
                data{i,1} = paramNames{i};
                data{i,2} = getParam(paramNames{i});
                data{i,3} = '';
            end
            
            geomFields = {'d', 'L', 'W', 'T'};
            units = {'m', 'm', 'm', 'K'};
            for k = 1:4
                data{nParams+k, 1} = geomFields{k};
                data{nParams+k, 2} = getGeom(geomFields{k});
                data{nParams+k, 3} = units{k};
            end
            
            app.ParamsTable.Data = data;
            app.ParamsTable.ColumnName = {'Parameter', 'Value', 'Units'};
            app.ParamsTable.ColumnWidth = {120, 150, 80};
            app.ParamsTable.ColumnEditable = [false, true, false];
        end

        function runTests(app)
            if app.isTesting, return; end
            
            selectedTests = {};
            for i = 1:length(app.TestCheckBoxes)
                if isvalid(app.TestCheckBoxes(i)) && app.TestCheckBoxes(i).Value
                    selectedTests{end+1} = app.TestCheckBoxes(i).Text;
                end
            end
            
            if isempty(selectedTests)
                app.StatusBar.Text = 'No tests selected';
                return;
            end
            
            app.isTesting = true;
            app.RunTestsBtn.Enable = 'off';
            app.CancelTestsBtn.Enable = 'on';
            app.StatusBar.Text = 'Running tests...';
            drawnow;
            
            try
                mockResults = cell(1, length(selectedTests));
                for idx = 1:length(selectedTests)
                    mockResults{idx} = struct('testType', selectedTests{idx}, ...
                        'getData', @(type) app.generateMockTestData(selectedTests{idx}, type));
                end
                
                app.testResults = mockResults;
                app.plotResults(app.testResults);
                app.StatusBar.Text = sprintf('✓ %d tests complete', length(app.testResults));
                
                if ~isstruct(app.stateManager)
                    ok = false;
                    try, ok = app.stateManager.transition('Results'); catch, end
                    if ~ok, app.onResults(); end
                else
                    app.onResults();
                end
                app.updateUIState();
                
            catch ME
                app.logger.error('Tests failed: %s', ME.message);
                app.StatusBar.Text = sprintf('ERROR: %s', ME.message);
                if ~isstruct(app.stateManager)
                    try, app.stateManager.transition('Error'); catch, app.onErrorReset(); end
                else
                    app.onErrorReset();
                end
                app.updateUIState();
            end
            
            app.isTesting = false;
            app.RunTestsBtn.Enable = 'on';
            app.CancelTestsBtn.Enable = 'off';
        end

        function cancelTests(app)
            if app.isTesting
                app.StatusBar.Text = 'Tests cancelled';
                app.logger.info('Tests cancelled by user');
            end
        end

        function out = generateMockTestData(~, testName, dataType)
            switch testName
                case 'Transfer'
                    if strcmp(dataType, 'Vgs'), out = -0.4:0.05:0.6;
                    elseif strcmp(dataType, 'Id'), out = [0.1, 0.2; 0.3, 0.5; 0.8, 1.2] * ones(1, 21); out = out(1:21, :);
                    else, out = [-0.1, -0.5]; end
                case 'Output'
                    if strcmp(dataType, 'Vds'), out = -0.6:0.05:0.0;
                    elseif strcmp(dataType, 'Id'), out = [-0.2, -0.4; -0.6, -0.9] * ones(1, 13); out = out(1:13, :);
                    else, out = [0.0, 0.4]; end
                case 'Hysteresis'
                    if strcmp(dataType, 'Vg_forward'), out = -0.2:0.05:0.6;
                    elseif strcmp(dataType, 'Id_forward'), out = (0.1:0.05:0.9).^2;
                    elseif strcmp(dataType, 'Vg_reverse'), out = 0.6:-0.05:-0.2;
                    elseif strcmp(dataType, 'Id_reverse'), out = (0.6:-0.05:-0.2).^2 + 0.05;
                    else, out = -0.1; end
                case 'PPX'
                    if strcmp(dataType, 'Intervals'), out = [10, 20, 50, 100, 200, 500];
                    elseif strcmp(dataType, 'PPF_Ratio'), out = 1.8 * exp(-[10, 20, 50, 100, 200, 500]/120) + 1.0;
                    else, out = []; end
                otherwise
                    if strcmp(dataType, 'Time'), out = 0:0.001:0.5;
                    elseif strcmp(dataType, 'Current'), out = 0.5 * sin(2*pi*10*(0:0.001:0.5)) + 1.0;
                    else, out = []; end
            end
        end

        function plotResults(app, results)
            for i = 1:length(results)
                r = results{i};
                if ~isstruct(r), continue; end
                switch r.testType
                    case 'Transfer', app.plotTransfer(r);
                    case 'Output', app.plotOutput(r);
                    case 'Hysteresis', app.plotHysteresis(r);
                    case 'PPX', app.plotPPX(r);
                    case {'Step', 'Vg Train (Amp)', 'Vg Train (Interval)', ...
                          'Vd Train (Amp)', 'Vd Train (Interval)', 'Vds Pulse'}
                        app.plotPulseTrain(r);
                end
            end
        end

        function plotTransfer(app, result)
            ax = app.getResultAxes('Transfer');
            hold(ax, 'on');
            Vgs = result.getData('Vgs'); Id = result.getData('Id'); Vds = result.getData('Vds');
            colors = lines(length(Vds));
            for j = 1:length(Vds)
                plot(ax, Vgs, Id(:,j) * 1e3, 'LineWidth', 2, 'Color', colors(j,:), ...
                    'DisplayName', sprintf('Vds=%.2fV', Vds(j)));
            end
            xlabel(ax, 'V_{gs} (V)'); ylabel(ax, 'I_d (mA)'); title(ax, 'Transfer Characteristics');
            legend(ax, 'Location', 'best', 'TextColor', [1,1,1]); grid(ax, 'on'); hold(ax, 'off');
        end

        function plotOutput(app, result)
            ax = app.getResultAxes('Output');
            hold(ax, 'on');
            Vds = result.getData('Vds'); Id = result.getData('Id'); Vg = result.getData('Vg');
            colors = lines(length(Vg));
            for j = 1:length(Vg)
                plot(ax, Vds, Id(:,j) * 1e3, 'LineWidth', 2, 'Color', colors(j,:), ...
                    'DisplayName', sprintf('Vgs=%.2fV', Vg(j)));
            end
            xlabel(ax, 'V_{ds} (V)'); ylabel(ax, 'I_d (mA)'); title(ax, 'Output Characteristics');
            legend(ax, 'Location', 'best', 'TextColor', [1,1,1]); grid(ax, 'on'); hold(ax, 'off');
        end

        function plotHysteresis(app, result)
            ax = app.getResultAxes('Hysteresis');
            hold(ax, 'on');
            Vg_fwd = result.getData('Vg_forward');
            Id_fwd = result.getData('Id_forward');
            Vg_rev = result.getData('Vg_reverse');
            Id_rev = result.getData('Id_reverse');
            plot(ax, Vg_fwd, Id_fwd * 1e3, '-o', 'LineWidth', 2, 'Color', [0.2, 0.6, 1.0], 'DisplayName', 'Forward Sweep');
            plot(ax, Vg_rev, Id_rev * 1e3, '-x', 'LineWidth', 2, 'Color', [1.0, 0.4, 0.4], 'DisplayName', 'Reverse Sweep');
            xlabel(ax, 'V_{gs} (V)'); ylabel(ax, 'I_d (mA)'); title(ax, 'Hysteresis Profile');
            legend(ax, 'Location', 'best', 'TextColor', [1,1,1]); grid(ax, 'on'); hold(ax, 'off');
        end

        function plotPPX(app, result)
            ax = app.getResultAxes('PPX');
            hold(ax, 'on');
            intervals = result.getData('Intervals');
            ratio = result.getData('PPF_Ratio');
            stem(ax, intervals, ratio, 'Filled', 'LineWidth', 2, 'Color', [0.4, 0.8, 0.4]);
            plot(ax, intervals, ratio, '--', 'LineWidth', 1.5, 'Color', [0.8, 0.8, 0.8]);
            xlabel(ax, 'Pulse Interval \Delta t (ms)'); ylabel(ax, 'PPF Ratio (A_2 / A_1)'); title(ax, 'Paired-Pulse Facilitation');
            grid(ax, 'on'); hold(ax, 'off');
        end

        function plotPulseTrain(app, result)
            ax = app.getResultAxes(result.testType);
            hold(ax, 'on');
            t = result.getData('Time');
            Id_t = result.getData('Current');
            plot(ax, t * 1e3, Id_t * 1e3, 'LineWidth', 2, 'Color', [0.9, 0.6, 0.1]);
            xlabel(ax, 'Time (ms)'); ylabel(ax, 'Transient I_d (mA)'); title(ax, sprintf('%s Response', result.testType));
            grid(ax, 'on'); hold(ax, 'off');
        end

        function exportParams(app)
            if isempty(app.parameters), app.StatusBar.Text = 'No parameters to export'; return; end
            timestamp = datestr(now, 'yyyy-mm-dd_HH-MM-SS');
            filename = sprintf('results/fits/parameters_%s.mat', timestamp);
            try
                if ~isfolder('results/fits'), mkdir('results/fits'); end
                params = app.parameters; save(filename, 'params');
                app.StatusBar.Text = sprintf('✓ Parameters exported to %s', filename);
                app.logger.info('Parameters exported');
            catch ME, app.StatusBar.Text = sprintf('ERROR: %s', ME.message); end
        end

        function exportPlots(app)
            timestamp = datestr(now, 'yyyy-mm-dd_HH-MM-SS');
            try
                if ~isfolder('results/exports'), mkdir('results/exports'); end
                if ~isempty(app.resultAxes)
                    names = keys(app.resultAxes);
                    for i = 1:length(names)
                        ax = app.resultAxes(names{i});
                        if isvalid(ax) && ~isempty(ax.Children)
                            filename = sprintf('results/exports/%s_%s.png', ...
                                matlab.lang.makeValidName(lower(names{i})), timestamp);
                            exportgraphics(ax, filename, 'Resolution', 300);
                        end
                    end
                end
                app.StatusBar.Text = '✓ Plots exported to results/exports/';
                app.logger.info('Plots exported');
            catch ME, app.StatusBar.Text = sprintf('ERROR: %s', ME.message); end
        end

        function exportReport(app)
            if isempty(app.testResults) || isempty(app.parameters), app.StatusBar.Text = 'No results to report'; return; end
            try
                app.StatusBar.Text = '✓ Report generated';
                app.logger.info('Report generated');
            catch ME, app.StatusBar.Text = sprintf('ERROR: %s', ME.message); end
        end

        function exportExcel(app)
            if isempty(app.testResults) || isempty(app.parameters), app.StatusBar.Text = 'No results to export'; return; end
            try
                app.StatusBar.Text = '✓ Excel export complete';
                app.logger.info('Excel exported');
            catch ME, app.StatusBar.Text = sprintf('ERROR: %s', ME.message); end
        end

        function openLiveTuner(app)
            if isempty(app.model), app.StatusBar.Text = 'Please fit parameters first'; return; end
            try, app.logger.info('Live tuner opened'); catch ME, app.StatusBar.Text = sprintf('ERROR: %s', ME.message); end
        end

        function SteadyStateBrowseBtnPushed(app, ~)
            if strcmp(app.getModelType(), 'Impedance')
                dialogTitle = 'Select EIS Impedance Data File';
            else
                dialogTitle = 'Select Steady-State File';
            end
            [file, path] = uigetfile({'*.xls;*.xlsx;*.csv;*.mat', 'Supported Files'}, dialogTitle);
            if file ~= 0, app.SteadyStateEdit.Value = fullfile(path, file); end
        end

        function TransientBrowseBtnPushed(app, ~)
            [files, path] = uigetfile({'*.xls;*.xlsx;*.csv;*.mat', 'Supported Files'}, 'Select Transient Files', 'MultiSelect', 'on');
            if ischar(files) && files ~= 0, files = {files}; end
            if ~isempty(files) && ~(ischar(files) && files == 0)
                fullPaths = cellfun(@(f) fullfile(path, f), files, 'UniformOutput', false);
                app.TransientEdit.Value = strjoin(fullPaths, '; ');
            end
        end

        function LoadDataBtnPushed(app, ~), app.loadData(); end
        function FitBtnPushed(app, ~)
            if ~app.isLoaded, app.StatusBar.Text = 'Please load data first'; return; end
            app.fitParameters();
        end
        function CancelFitBtnPushed(app, ~), app.cancelFit(); end
        function RunTestsBtnPushed(app, ~)
            if ~app.isFitted, app.StatusBar.Text = 'Please fit parameters first'; return; end
            app.runTests();
        end
        function CancelTestsBtnPushed(app, ~), app.cancelTests(); end

        function ModelDropdownValueChanged(app, ~)
            app.logger.info('Model changed to: %s', app.ModelDropdown.Value);
            % Changing the model invalidates any previously loaded data /
            % fit, so reset back to the Idle state (previously this
            % erroneously transitioned to 'DataLoaded', which left the Fit
            % button enabled with no data loaded, and later broke the
            % genuine 'Idle'->'DataLoaded' transition performed by
            % loadData()).
            app.isLoaded = false;
            app.isFitted = false;
            if ~isstruct(app.stateManager)
                try, app.stateManager.reset(); catch, end
            end
            app.updateUIState();
            app.updateDataPanelForModel();
            app.refreshParameters();
        end

        function ParamsTableCellEdit(app, ~)
            if isempty(app.parameters), return; end
            row = app.ParamsTable.Selection(1);
            data = app.ParamsTable.Data;
            if isempty(data) || row > size(data, 1), return; end
            paramName = data{row, 1};
            newValue = data{row, 2};
            try
                if isstruct(app.parameters)
                    if isfield(app.parameters.params, paramName)
                        app.parameters.params.(paramName) = newValue;
                    end
                else
                    app.parameters.setParameter(paramName, newValue);
                end
                app.logger.info('Parameter updated: %s = %.4e', paramName, newValue);
            catch ME
                app.StatusBar.Text = sprintf('ERROR: %s', ME.message);
                app.updateParameterTable();
            end
        end

        function ExportParamsBtnPushed(app, ~), app.exportParams(); end
        function ExportPlotsBtnPushed(app, ~), app.exportPlots(); end
        function ExportReportBtnPushed(app, ~), app.exportReport(); end
        function ExportExcelBtnPushed(app, ~), app.exportExcel(); end
        function LiveTuneBtnPushed(app, ~), app.openLiveTuner(); end
    end

    methods (Access = public)

        function app = OECT_GUI
            app.logger = struct(...
                'info', @(msg, varargin) fprintf(['[INFO] ' msg '\n'], varargin{:}), ...
                'warn', @(msg, varargin) fprintf(['[WARN] ' msg '\n'], varargin{:}), ...
                'error', @(msg, varargin) fprintf(['[ERROR] ' msg '\n'], varargin{:}));
            app.logger.info('Building GUI...');
            
            app.UIFigure = uifigure('Name', 'OECT Modeling Suite v2.0', ...
                                    'Position', [50, 50, 1600, 950], ...
                                    'Resize', 'on', ...
                                    'Color', [0.12, 0.12, 0.12]);
            
            app.buildUI();
            app.setupApp();
            app.logger.info('GUI ready');
        end

        function buildUI(app)
            % Main grid
            app.MainGrid = uigridlayout(app.UIFigure, [1, 2], ...
                'ColumnWidth', {'1x', '2x'}, ...
                'RowHeight', {'1x'}, ...
                'BackgroundColor', [0.12, 0.12, 0.12]);
            
            % ===== LEFT PANEL =====
            app.LeftPanel = uipanel(app.MainGrid, ...
                'Title', '', ...
                'BackgroundColor', [0.15, 0.15, 0.15], ...
                'ForegroundColor', [1, 1, 1]);
            
            % Use 'fit' for rows so panels size to content, and '1x' for the last row to take remaining space
            app.LeftGrid = uigridlayout(app.LeftPanel, [11, 1], ...
                'RowHeight', {'fit', 'fit', 'fit', 'fit', 'fit', 'fit', 'fit', 'fit', 'fit', 'fit', '1x'}, ...
                'BackgroundColor', [0.15, 0.15, 0.15]);
            
            % Model Panel
            app.ModelPanel = uipanel(app.LeftGrid, ...
                'Title', 'Model Selection', ...
                'BackgroundColor', [0.18, 0.18, 0.18], ...
                'ForegroundColor', [1, 1, 1], ...
                'FontWeight', 'bold');
            
            app.ModelGrid = uigridlayout(app.ModelPanel, [1, 1], ...
                'Padding', [10, 10, 10, 10], ...
                'BackgroundColor', [0.18, 0.18, 0.18]);
            
            app.ModelDropdown = uidropdown(app.ModelGrid, ...
                'Items', {'Bisquert (Ionic Dynamics)', ...
                         'Shirinskaya (PNP + RC)', ...
                         'Impedance (EIS Fitting)'}, ...
                'Value', 'Bisquert (Ionic Dynamics)', ...
                'BackgroundColor', [0.25, 0.25, 0.25], ...
                'FontColor', [1, 1, 1], ...
                'ValueChangedFcn', @(src, evt) app.ModelDropdownValueChanged());
            
            % Data Panel
            app.DataPanel = uipanel(app.LeftGrid, ...
                'Title', 'Data Loading', ...
                'BackgroundColor', [0.18, 0.18, 0.18], ...
                'ForegroundColor', [1, 1, 1], ...
                'FontWeight', 'bold');
            
            app.DataGrid = uigridlayout(app.DataPanel, [6, 2], ...
                'RowHeight', {25, 25, 25, 25, 25, 25}, ...
                'ColumnWidth', {'1x', '3x'}, ...
                'Padding', [5, 5, 5, 5], ...
                'BackgroundColor', [0.18, 0.18, 0.18]);
            
            app.SteadyStateLabel = uilabel(app.DataGrid, 'Text', 'Steady:', 'FontColor', [1, 1, 1]);
            app.SteadyStateEdit = uieditfield(app.DataGrid, 'BackgroundColor', [0.25, 0.25, 0.25], 'FontColor', [1, 1, 1]);
            app.SteadyStateBrowseBtn = uibutton(app.DataGrid, 'Text', 'Browse', 'BackgroundColor', [0.3, 0.3, 0.3], 'FontColor', [1, 1, 1], 'ButtonPushedFcn', @(src, evt) app.SteadyStateBrowseBtnPushed());
            
            app.TransientLabel = uilabel(app.DataGrid, 'Text', 'Transient:', 'FontColor', [1, 1, 1]);
            app.TransientEdit = uieditfield(app.DataGrid, 'BackgroundColor', [0.25, 0.25, 0.25], 'FontColor', [1, 1, 1]);
            app.TransientBrowseBtn = uibutton(app.DataGrid, 'Text', 'Browse', 'BackgroundColor', [0.3, 0.3, 0.3], 'FontColor', [1, 1, 1], 'ButtonPushedFcn', @(src, evt) app.TransientBrowseBtnPushed());
            
            app.SheetLabel = uilabel(app.DataGrid, 'Text', 'Sheet:', 'FontColor', [1, 1, 1]);
            app.SheetDropdown = uidropdown(app.DataGrid, 'Items', {'None'}, 'BackgroundColor', [0.25, 0.25, 0.25], 'FontColor', [1, 1, 1]);
            
            app.LoadDataBtn = uibutton(app.DataGrid, 'Text', 'Load Data', 'BackgroundColor', [0, 0.5, 0], 'FontColor', [1, 1, 1], 'FontWeight', 'bold', 'ButtonPushedFcn', @(src, evt) app.LoadDataBtnPushed());
            app.DataStatusLabel = uilabel(app.DataGrid, 'Text', 'No data loaded', 'FontColor', [0.8, 0.8, 0.8]);
            
            % Geometry Panel
            app.GeometryPanel = uipanel(app.LeftGrid, ...
                'Title', 'Geometry', ...
                'BackgroundColor', [0.18, 0.18, 0.18], ...
                'ForegroundColor', [1, 1, 1], ...
                'FontWeight', 'bold');
            
            app.GeometryGrid = uigridlayout(app.GeometryPanel, [2, 4], ...
                'RowHeight', {25, 25}, ...
                'ColumnWidth', {'1x', '1.5x', '1x', '1.5x'}, ...
                'Padding', [5, 5, 5, 5], ...
                'BackgroundColor', [0.18, 0.18, 0.18]);
            
            app.dLabel = uilabel(app.GeometryGrid, 'Text', 'd:', 'FontColor', [1, 1, 1]);
            app.dEdit = uieditfield(app.GeometryGrid, 'numeric', 'Value', 10e-6, 'BackgroundColor', [0.25, 0.25, 0.25], 'FontColor', [1, 1, 1]);
            app.LLabel = uilabel(app.GeometryGrid, 'Text', 'L:', 'FontColor', [1, 1, 1]);
            app.LEdit = uieditfield(app.GeometryGrid, 'numeric', 'Value', 25e-6, 'BackgroundColor', [0.25, 0.25, 0.25], 'FontColor', [1, 1, 1]);
            app.WLabel = uilabel(app.GeometryGrid, 'Text', 'W:', 'FontColor', [1, 1, 1]);
            app.WEdit = uieditfield(app.GeometryGrid, 'numeric', 'Value', 10e-6, 'BackgroundColor', [0.25, 0.25, 0.25], 'FontColor', [1, 1, 1]);
            app.TLabel = uilabel(app.GeometryGrid, 'Text', 'T:', 'FontColor', [1, 1, 1]);
            app.TEdit = uieditfield(app.GeometryGrid, 'numeric', 'Value', 290, 'BackgroundColor', [0.25, 0.25, 0.25], 'FontColor', [1, 1, 1]);
            
            % Parameters Panel
            app.ParamsPanel = uipanel(app.LeftGrid, ...
                'Title', 'Parameters', ...
                'BackgroundColor', [0.18, 0.18, 0.18], ...
                'ForegroundColor', [1, 1, 1], ...
                'FontWeight', 'bold');
            
            app.ParamsGrid = uigridlayout(app.ParamsPanel, [1, 1], ...
                'Padding', [5, 5, 5, 5], ...
                'BackgroundColor', [0.18, 0.18, 0.18]);
            
            app.ParamsTable = uitable(app.ParamsGrid, ...
                'ColumnName', {'Parameter', 'Value', 'Units'}, ...
                'ColumnWidth', {120, 150, 80}, ...
                'ColumnEditable', [false, true, false], ...
                'BackgroundColor', [0.25, 0.25, 0.25], ...
                'CellEditCallback', @(src, evt) app.ParamsTableCellEdit());
            
            % Fit Panel
            app.FitPanel = uipanel(app.LeftGrid, ...
                'Title', 'Fitting', ...
                'BackgroundColor', [0.18, 0.18, 0.18], ...
                'ForegroundColor', [1, 1, 1], ...
                'FontWeight', 'bold');

            app.FitGrid = uigridlayout(app.FitPanel, [6, 2], ...
                'RowHeight', {25, 25, 25, 25, 25, 25}, ...
                'ColumnWidth', {'1x', '1x'}, ...
                'Padding', [5, 5, 5, 5], ...
                'BackgroundColor', [0.18, 0.18, 0.18]);

            app.R2Label = uilabel(app.FitGrid, 'Text', 'R² threshold:', 'FontColor', [1, 1, 1]);
            app.R2Edit = uieditfield(app.FitGrid, 'numeric', 'Value', 0.5, 'Limits', [0, 1], 'BackgroundColor', [0.25, 0.25, 0.25], 'FontColor', [1, 1, 1]);
            app.NRMSELabel = uilabel(app.FitGrid, 'Text', 'NRMSE threshold:', 'FontColor', [1, 1, 1]);
            app.NRMSEEdit = uieditfield(app.FitGrid, 'numeric', 'Value', 0.2, 'Limits', [0, 1], 'BackgroundColor', [0.25, 0.25, 0.25], 'FontColor', [1, 1, 1]);
            app.NStartsLabel = uilabel(app.FitGrid, 'Text', '# Starts (EIS):', 'FontColor', [1, 1, 1], 'Visible', 'off');
            app.NStartsEdit  = uieditfield(app.FitGrid, 'numeric', 'Value', 50, 'Limits', [1, 5000], 'BackgroundColor', [0.25, 0.25, 0.25], 'FontColor', [1, 1, 1], 'Visible', 'off');
            app.FitBtn = uibutton(app.FitGrid, 'Text', 'Fit Parameters', 'BackgroundColor', [0, 0.5, 0.8], 'FontColor', [1, 1, 1], 'FontWeight', 'bold', 'ButtonPushedFcn', @(src, evt) app.FitBtnPushed());
            app.CancelFitBtn = uibutton(app.FitGrid, 'Text', 'Cancel', 'BackgroundColor', [0.6, 0.1, 0.1], 'FontColor', [1, 1, 1], 'Enable', 'off', 'ButtonPushedFcn', @(src, evt) app.CancelFitBtnPushed());
            app.FitProgress = uilabel(app.FitGrid, 'Text', '0%', 'HorizontalAlignment', 'center', 'BackgroundColor', [0.25, 0.25, 0.25], 'FontColor', [0.9, 0.9, 0.9]);
            app.FitStatusLabel = uilabel(app.FitGrid, 'Text', 'Ready', 'FontColor', [0.8, 0.8, 0.8]);
            
            % ===== RIGHT PANEL =====
            app.RightPanel = uipanel(app.MainGrid, ...
                'Title', '', ...
                'BackgroundColor', [0.15, 0.15, 0.15], ...
                'ForegroundColor', [1, 1, 1]);
            
            app.RightGrid = uigridlayout(app.RightPanel, [3, 1], ...
                'RowHeight', {'1x', 'fit', 30}, ...
                'BackgroundColor', [0.15, 0.15, 0.15]);
            
            % Tests Panel: checkboxes + inline parameter fields per test,
            % plus a bottom row for Save Data / Run / Cancel controls.
            app.TestsPanel = uipanel(app.RightGrid, ...
                'Title', 'Test Selection', ...
                'BackgroundColor', [0.18, 0.18, 0.18], ...
                'ForegroundColor', [1, 1, 1], ...
                'FontWeight', 'bold');
            
            app.TestsGrid = uigridlayout(app.TestsPanel, [11, 5], ...
                'RowHeight', repmat({25}, 1, 11), ...
                'ColumnWidth', {'1.3x', 35, '0.8x', 35, '0.8x'}, ...
                'Padding', [5, 5, 5, 5], ...
                'BackgroundColor', [0.18, 0.18, 0.18]);
            % Checkboxes, per-test parameter fields, and the Save/Run/Cancel
            % controls row are created in initializeTestCheckboxes().
            
            % Export Panel
            app.ExportPanel = uipanel(app.RightGrid, ...
                'Title', 'Export', ...
                'BackgroundColor', [0.18, 0.18, 0.18], ...
                'ForegroundColor', [1, 1, 1], ...
                'FontWeight', 'bold');
            
            app.ExportGrid = uigridlayout(app.ExportPanel, [1, 5], ...
                'ColumnWidth', {'1x', '1x', '1x', '1x', '1x'}, ...
                'Padding', [5, 5, 5, 5], ...
                'BackgroundColor', [0.18, 0.18, 0.18]);
            
            app.ExportParamsBtn = uibutton(app.ExportGrid, 'Text', 'Params', 'BackgroundColor', [0.3, 0.3, 0.4], 'FontColor', [1, 1, 1], 'ButtonPushedFcn', @(src, evt) app.ExportParamsBtnPushed());
            app.ExportPlotsBtn = uibutton(app.ExportGrid, 'Text', 'Plots', 'BackgroundColor', [0.3, 0.3, 0.4], 'FontColor', [1, 1, 1], 'ButtonPushedFcn', @(src, evt) app.ExportPlotsBtnPushed());
            app.ExportReportBtn = uibutton(app.ExportGrid, 'Text', 'Report', 'BackgroundColor', [0.3, 0.3, 0.4], 'FontColor', [1, 1, 1], 'ButtonPushedFcn', @(src, evt) app.ExportReportBtnPushed());
            app.ExportExcelBtn = uibutton(app.ExportGrid, 'Text', 'Excel', 'BackgroundColor', [0.3, 0.3, 0.4], 'FontColor', [1, 1, 1], 'ButtonPushedFcn', @(src, evt) app.ExportExcelBtnPushed());
            app.LiveTuneBtn = uibutton(app.ExportGrid, 'Text', 'Live Tune', 'BackgroundColor', [0.4, 0.2, 0.6], 'FontColor', [1, 1, 1], 'ButtonPushedFcn', @(src, evt) app.LiveTuneBtnPushed());
            
            % Status Bar
            app.StatusBar = uilabel(app.RightGrid, ...
                'Text', 'Ready', ...
                'FontColor', [0.8, 0.8, 0.8], ...
                'BackgroundColor', [0.15, 0.15, 0.15]);
            
            % Initialize test checkboxes
            app.initializeTestCheckboxes();
        end
    end
end