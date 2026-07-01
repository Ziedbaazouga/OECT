classdef ReportGenerator < handle
    %OECT.REPORTGENERATOR Generate reports in various formats
    
    properties
        OutputDir char = 'results/exports'
        Template char = 'standard'
        IncludePlots logical = true
        IncludeRawData logical = false
        IncludeCode logical = false
    end
    
    properties (Access = private)
        logger
        content struct
    end
    
    methods
        function obj = ReportGenerator()
            obj.logger = OECT.Logger('ReportGenerator');
            obj.content = struct();
            
            % Create output directory
            if ~exist(obj.OutputDir, 'dir')
                mkdir(obj.OutputDir);
            end
        end
        
        function generatePDF(obj, results, parameters, title)
            % Generate PDF report
            if nargin < 4
                title = 'OECT Modeling Report';
            end
            
            timestamp = datestr(now, 'yyyy-mm-dd_HH-MM-SS');
            filename = fullfile(obj.OutputDir, sprintf('report_%s.pdf', timestamp));
            
            obj.logger.info('Generating PDF: %s', filename);
            
            % Build content
            obj.content.title = title;
            obj.content.date = datestr(now);
            obj.content.parameters = parameters;
            obj.content.results = results;
            obj.content.summary = obj.generateSummary(results);
            
            % Create LaTeX content
            latex = obj.buildLaTeX();
            
            % Save LaTeX file
            texFile = strrep(filename, '.pdf', '.tex');
            fid = fopen(texFile, 'w');
            fprintf(fid, '%s', latex);
            fclose(fid);
            
            % Try to compile using pdflatex if available
            try
                if obj.checkLatexAvailable()
                    obj.compilePDF(texFile);
                    obj.logger.info('PDF generated successfully');
                else
                    obj.logger.warn('LaTeX not available, saving .tex file only');
                end
            catch ME
                obj.logger.warn('PDF compilation failed: %s', ME.message);
            end
            
            % Also save as MAT for fallback
            matFile = strrep(filename, '.pdf', '.mat');
            save(matFile, 'obj.content');
            obj.logger.info('MAT fallback saved: %s', matFile);
        end
        
        function generateHTML(obj, results, parameters, title)
            % Generate HTML report
            if nargin < 4
                title = 'OECT Modeling Report';
            end
            
            timestamp = datestr(now, 'yyyy-mm-dd_HH-MM-SS');
            filename = fullfile(obj.OutputDir, sprintf('report_%s.html', timestamp));
            
            obj.logger.info('Generating HTML: %s', filename);
            
            html = obj.buildHTML(results, parameters, title);
            
            fid = fopen(filename, 'w');
            fprintf(fid, '%s', html);
            fclose(fid);
            
            obj.logger.info('HTML generated: %s', filename);
        end
        
        function summary = generateSummary(obj, results)
            summary = struct();
            summary.n_tests = length(results);
            summary.test_names = {};
            summary.test_types = {};
            summary.keys = {};
            
            for i = 1:length(results)
                if isa(results{i}, 'OECT.TestResult')
                    summary.test_names{end+1} = results{i}.testName;
                    summary.test_types{end+1} = results{i}.testType;
                    if ~isempty(results{i}.summary)
                        fnames = fieldnames(results{i}.summary);
                        for j = 1:length(fnames)
                            key = sprintf('%s_%s', results{i}.testName, fnames{j});
                            summary.keys{end+1} = key;
                            summary.(key) = results{i}.summary.(fnames{j});
                        end
                    end
                end
            end
        end
        
        function latex = buildLaTeX(obj)
            % Build LaTeX document
            
            latex = [];
            
            % Document header
            latex = [latex, '\documentclass[11pt,a4paper]{article}\n'];
            latex = [latex, '\\usepackage{geometry}\n'];
            latex = [latex, '\\usepackage{graphicx}\n'];
            latex = [latex, '\\usepackage{booktabs}\n'];
            latex = [latex, '\\usepackage{amsmath}\n'];
            latex = [latex, '\\usepackage{siunitx}\n'];
            latex = [latex, '\\geometry{margin=1in}\n'];
            latex = [latex, '\\begin{document}\n\n'];
            
            % Title
            latex = [latex, '\\title{', obj.content.title, '}\n'];
            latex = [latex, '\\author{OECT Modeling Suite v2.0}\n'];
            latex = [latex, '\\date{', obj.content.date, '}\n'];
            latex = [latex, '\\maketitle\n\n'];
            
            % Parameters section
            latex = [latex, '\\section*{Model Parameters}\n'];
            latex = [latex, '\\begin{tabular}{l r r}\n'];
            latex = [latex, '\\toprule\n'];
            latex = [latex, 'Parameter & Value & Units \\\\\n'];
            latex = [latex, '\\midrule\n'];
            
            p = obj.content.parameters;
            if isa(p, 'OECT.Parameters')
                paramNames = fieldnames(p.params);
                for i = 1:length(paramNames)
                    name = paramNames{i};
                    val = p.params.(name);
                    latex = [latex, sprintf('%s & %.4e & \\\\\n', name, val)];
                end
                % Geometry
                latex = [latex, sprintf('d & %.2e & m\\\\\n', p.geometry.d)];
                latex = [latex, sprintf('L & %.2e & m\\\\\n', p.geometry.L)];
                latex = [latex, sprintf('W & %.2e & m\\\\\n', p.geometry.W)];
                latex = [latex, sprintf('T & %.1f & K\\\\\n', p.geometry.T)];
            end
            
            latex = [latex, '\\bottomrule\n'];
            latex = [latex, '\\end{tabular}\n\n'];
            
            % Results section
            latex = [latex, '\\section*{Test Results}\n'];
            
            for i = 1:length(obj.content.results)
                r = obj.content.results{i};
                if isa(r, 'OECT.TestResult')
                    latex = [latex, '\\subsection*{', r.testName, '}\n'];
                    latex = [latex, '\\begin{tabular}{l r}\n'];
                    latex = [latex, '\\toprule\n'];
                    latex = [latex, 'Metric & Value \\\\\n'];
                    latex = [latex, '\\midrule\n'];
                    
                    if ~isempty(r.summary)
                        fnames = fieldnames(r.summary);
                        for j = 1:length(fnames)
                            name = fnames{j};
                            val = r.summary.(name);
                            if isnumeric(val) && numel(val) == 1
                                latex = [latex, sprintf('%s & %.4f \\\\\n', name, val)];
                            end
                        end
                    end
                    
                    latex = [latex, '\\bottomrule\n'];
                    latex = [latex, '\\end{tabular}\n\n'];
                end
            end
            
            latex = [latex, '\\end{document}\n'];
        end
        
        function html = buildHTML(obj, results, parameters, title)
            % Build HTML report
            
            html = [];
            
            % HTML header
            html = [html, '<!DOCTYPE html>\n'];
            html = [html, '<html>\n'];
            html = [html, '<head>\n'];
            html = [html, '  <meta charset="UTF-8">\n'];
            html = [html, '  <title>', title, '</title>\n'];
            html = [html, '  <style>\n'];
            html = [html, '    body { font-family: Arial, sans-serif; margin: 40px; background: #1a1a1a; color: #e0e0e0; }\n'];
            html = [html, '    h1 { color: #00bfff; }\n'];
            html = [html, '    h2 { color: #ffa500; }\n'];
            html = [html, '    table { border-collapse: collapse; width: 100%%; margin: 10px 0; }\n'];
            html = [html, '    th, td { border: 1px solid #444; padding: 8px; text-align: left; }\n'];
            html = [html, '    th { background: #333; color: #fff; }\n'];
            html = [html, '    tr:nth-child(even) { background: #222; }\n'];
            html = [html, '    .container { max-width: 1200px; margin: 0 auto; }\n'];
            html = [html, '    .section { background: #2a2a2a; padding: 20px; margin: 20px 0; border-radius: 8px; }\n'];
            html = [html, '  </style>\n'];
            html = [html, '</head>\n'];
            html = [html, '<body>\n'];
            html = [html, '  <div class="container">\n'];
            
            % Title
            html = [html, '    <h1>', title, '</h1>\n'];
            html = [html, '    <p>Generated: ', datestr(now), '</p>\n'];
            
            % Parameters
            html = [html, '    <div class="section">\n'];
            html = [html, '      <h2>Model Parameters</h2>\n'];
            html = [html, '      <table>\n'];
            html = [html, '        <tr><th>Parameter</th><th>Value</th><th>Units</th></tr>\n'];
            
            if isa(parameters, 'OECT.Parameters')
                paramNames = fieldnames(parameters.params);
                for i = 1:length(paramNames)
                    name = paramNames{i};
                    val = parameters.params.(name);
                    html = [html, sprintf('        <tr><td>%s</td><td>%.4e</td><td></td></tr>\n', name, val)];
                end
                html = [html, sprintf('        <tr><td>d</td><td>%.2e</td><td>m</td></tr>\n', parameters.geometry.d)];
                html = [html, sprintf('        <tr><td>L</td><td>%.2e</td><td>m</td></tr>\n', parameters.geometry.L)];
                html = [html, sprintf('        <tr><td>W</td><td>%.2e</td><td>m</td></tr>\n', parameters.geometry.W)];
                html = [html, sprintf('        <tr><td>T</td><td>%.1f</td><td>K</td></tr>\n', parameters.geometry.T)];
            end
            
            html = [html, '      </table>\n'];
            html = [html, '    </div>\n'];
            
            % Results
            html = [html, '    <div class="section">\n'];
            html = [html, '      <h2>Test Results</h2>\n'];
            
            for i = 1:length(results)
                if isa(results{i}, 'OECT.TestResult')
                    r = results{i};
                    html = [html, '      <h3>', r.testName, '</h3>\n'];
                    html = [html, '      <table>\n'];
                    html = [html, '        <tr><th>Metric</th><th>Value</th></tr>\n'];
                    
                    if ~isempty(r.summary)
                        fnames = fieldnames(r.summary);
                        for j = 1:length(fnames)
                            name = fnames{j};
                            val = r.summary.(name);
                            if isnumeric(val) && numel(val) == 1
                                html = [html, sprintf('        <tr><td>%s</td><td>%.4f</td></tr>\n', name, val)];
                            end
                        end
                    end
                    
                    html = [html, '      </table>\n'];
                end
            end
            
            html = [html, '    </div>\n'];
            html = [html, '  </div>\n'];
            html = [html, '</body>\n'];
            html = [html, '</html>\n'];
        end
        
        function tf = checkLatexAvailable(obj)
            % Check if pdflatex is available
            [status, ~] = system('which pdflatex');
            tf = status == 0;
        end
        
        function compilePDF(obj, texFile)
            % Compile LaTeX to PDF
            [path, name, ~] = fileparts(texFile);
            oldDir = pwd;
            cd(path);
            system(sprintf('pdflatex -interaction=batchmode %s', name));
            cd(oldDir);
        end
        
        function exportCSV(obj, results, filename)
            % Export results as CSV
            if nargin < 3
                timestamp = datestr(now, 'yyyy-mm-dd_HH-MM-SS');
                filename = fullfile(obj.OutputDir, sprintf('results_%s.csv', timestamp));
            end
            
            obj.logger.info('Exporting CSV: %s', filename);
            
            fid = fopen(filename, 'w');
            
            % Write header
            fprintf(fid, 'Test,Parameter,Value\n');
            
            for i = 1:length(results)
                if isa(results{i}, 'OECT.TestResult')
                    r = results{i};
                    if ~isempty(r.summary)
                        fnames = fieldnames(r.summary);
                        for j = 1:length(fnames)
                            name = fnames{j};
                            val = r.summary.(name);
                            if isnumeric(val) && numel(val) == 1
                                fprintf(fid, '%s,%s,%.6f\n', r.testName, name, val);
                            end
                        end
                    end
                end
            end
            
            fclose(fid);
            obj.logger.info('CSV exported: %s', filename);
        end
        
        function exportExcel(obj, results, parameters, filename)
            % Export to Excel
            if nargin < 4
                timestamp = datestr(now, 'yyyy-mm-dd_HH-MM-SS');
                filename = fullfile(obj.OutputDir, sprintf('results_%s.xlsx', timestamp));
            end
            
            obj.logger.info('Exporting Excel: %s', filename);
            
            % Prepare data
            data = {};
            data{1,1} = 'Parameter';
            data{1,2} = 'Value';
            
            row = 2;
            if isa(parameters, 'OECT.Parameters')
                paramNames = fieldnames(parameters.params);
                for i = 1:length(paramNames)
                    data{row,1} = paramNames{i};
                    data{row,2} = parameters.params.(paramNames{i});
                    row = row + 1;
                end
                data{row,1} = 'd';
                data{row,2} = parameters.geometry.d;
                row = row + 1;
                data{row,1} = 'L';
                data{row,2} = parameters.geometry.L;
                row = row + 1;
                data{row,1} = 'W';
                data{row,2} = parameters.geometry.W;
                row = row + 1;
                data{row,1} = 'T';
                data{row,2} = parameters.geometry.T;
            end
            
            % Results
            resultData = {};
            resultData{1,1} = 'Test';
            resultData{1,2} = 'Metric';
            resultData{1,3} = 'Value';
            
            rrow = 2;
            for i = 1:length(results)
                if isa(results{i}, 'OECT.TestResult')
                    r = results{i};
                    if ~isempty(r.summary)
                        fnames = fieldnames(r.summary);
                        for j = 1:length(fnames)
                            name = fnames{j};
                            val = r.summary.(name);
                            if isnumeric(val) && numel(val) == 1
                                resultData{rrow,1} = r.testName;
                                resultData{rrow,2} = name;
                                resultData{rrow,3} = val;
                                rrow = rrow + 1;
                            end
                        end
                    end
                end
            end
            
            % Write to Excel
            try
                writecell(data, filename, 'Sheet', 'Parameters');
                writecell(resultData, filename, 'Sheet', 'Results');
                obj.logger.info('Excel exported: %s', filename);
            catch ME
                obj.logger.warn('Excel export failed: %s', ME.message);
                % Fallback to CSV
                obj.exportCSV(results);
            end
        end
    end
end