function main(varargin)
%MAIN Entry point for OECT Modeling Suite
%   main() - Launches GUI
%   main('batch') - Runs batch processing
%   main('test') - Runs unit tests
%   main('version') - Displays version

    % Add all paths
    setupPaths();
    
    % Parse arguments
    if nargin > 0
        switch varargin{1}
            case 'batch'
                runBatchMode();
            case 'test'
                runTests();
            case 'version'
                displayVersion();
            otherwise
                launchGUI();
        end
    else
        launchGUI();
    end
end

function setupPaths()
    % Add all required paths
    baseDir = fileparts(mfilename('fullpath'));
    addpath(genpath(baseDir));
    
    % Create required directories
    dirs = {'data', 'results', 'results/fits', 'results/simulations', ...
            'results/exports', 'config'};
    for i = 1:length(dirs)
        dirPath = fullfile(baseDir, dirs{i});
        if ~exist(dirPath, 'dir')
            mkdir(dirPath);
        end
    end
end

function launchGUI()
    % Launch the main GUI
    app = OECT_GUI();
    uiwait(app.UIFigure);
end

function runBatchMode()
    % Batch processing mode
    fprintf('OECT Modeling Suite - Batch Mode\n');
    fprintf('=================================\n');
    
    % Load configuration
    configFile = 'config/batch_config.mat';
    if ~isfile(configFile)
        error('Batch configuration not found. Create config/batch_config.mat');
    end
    
    load(configFile);
    
    % Process each batch item
    for i = 1:length(batch)
        fprintf('Processing %d/%d: %s\n', i, length(batch), batch(i).name);
        
        % Load data
        loader = OECT.DataLoader();
        loader.loadSteadyState(batch(i).steadyStateFile);
        loader.loadTransient(batch(i).transientFiles);
        
        % Create model
        model = OECT.BisquertModel();
        
        % Fit
        fitResults = model.fit(loader);
        
        % Run tests
        testSuite = OECT.TestSuite(model);
        results = testSuite.runSelected(batch(i).tests);
        
        % Generate report
        report = OECT.ReportGenerator();
        report.generatePDF(results, model.getParameters(), batch(i).name);
    end
    
    fprintf('Batch processing complete\n');
end

function runTests()
    % Run unit tests
    fprintf('Running unit tests...\n');
    
    % Test parameter creation
    p = OECT.Parameters('Bisquert');
    assert(p.isValid, 'Parameter validation failed');
    
    % Test model
    model = OECT.BisquertModel(p);
    t = linspace(0, 0.1, 100);
    Vg = -0.2 * ones(size(t));
    sim = model.simulate(Vg, t, -0.1);
    assert(length(sim.Id) == 100, 'Simulation length mismatch');
    
    fprintf('All tests passed!\n');
end

function displayVersion()
    fprintf('OECT Modeling Suite v2.0.0\n');
    fprintf('Copyright 2024\n');
    fprintf('Supported models: Bisquert, Shirinskaya, Impedance\n');
    fprintf('MATLAB version: %s\n', version);
end