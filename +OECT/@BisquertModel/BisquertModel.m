classdef BisquertModel < OECT.Model
    properties (Access = private)
        VT double
        cache struct = struct()
    end
    
    methods
        function obj = BisquertModel(parameters)
            if nargin < 1
                parameters = OECT.Parameters('Bisquert');
            end
            obj@OECT.Model(parameters);
            obj.modelName = 'Bisquert';
            obj.logger = OECT.Logger('BisquertModel');
            obj.computeConstants();
        end
        
        function computeConstants(obj)
            obj.VT = (obj.parameters.kB * obj.parameters.T) / obj.parameters.q;
        end
        
        function mu = getHolesMobility(obj)
            if isfield(obj.parameters.params, 'holes_mobility')
                mu = obj.parameters.params.holes_mobility;
            else
                error('Missing params.holes_mobility in OECT.Parameters');
            end
        end
        
        function sim = simulate(obj, Vg, t, Vds)
            obj.checkStop();
            P0 = obj.parameters.P0;
            M0 = obj.parameters.M0;
            tau_de = obj.parameters.tau_de;
            f = obj.parameters.f;
            uc = obj.parameters.uc;
            L = obj.parameters.L;
            mu_p = obj.getHolesMobility();
            q = obj.parameters.q;
            VT = obj.VT;
            
            t = t(:); Vg = Vg(:); n = length(t);
            if isscalar(Vds), Vds = Vds * ones(n,1); else, Vds = Vds(:); end
            
            Id = zeros(n,1); M = zeros(n,1);
            Meq_func = @(v) (2/3) * M0 * max((abs(v - uc))/VT, 0)^(1.5);
            M(1) = Meq_func(Vg(1));
            
            for i = 1:n
                dt = 0; if i > 1, dt = t(i)-t(i-1); end
                vmag = max(abs(Vds(i)), 1e-6);
                tau_e = (L^2)/(mu_p*vmag);
                theta = sign(Vds(i)); if theta == 0, theta = 1; end
                Meq = Meq_func(Vg(i));
                dMdt = (Meq - M(i))/max(tau_de,1e-9);
                if i < n, M(i+1) = M(i) + dMdt*dt; end
                Id(i) = theta*(q*L/tau_e)*max(P0-M(i),0) - q*f*L*dMdt;
            end
            
            sim = struct('t',t,'Id',Id,'Vgs',Vg,'Vds',Vds,'M',M);
        end
        
        function fitResults = fit(obj, data)
            obj.logger.info('Starting Bisquert model fit');
            nFiles = obj.getTransientCount(data);
            obj.logger.info('Data: %d transient files', nFiles);
            
            allResults = cell(nFiles,1);
            obj.logger.info('Using serial processing');
            for i = 1:nFiles
                allResults{i} = obj.fitSingleFile(data, i);
                if obj.stopFlag, break; end
            end
            fitResults = obj.aggregateFits(allResults);
            obj.logger.info('Fit complete. R2 = %.4f', fitResults.avgR2);
        end
        
        function result = fitSingleFile(obj, data, idx)
            parsed = obj.getTransientRecord(data, idx);
            
            if isfield(parsed,'filename_Vgs') && isfinite(parsed.filename_Vgs)
                Vgs = parsed.filename_Vgs;
            elseif isfield(parsed,'Vgs') && ~isempty(parsed.Vgs)
                Vgs = mean(parsed.Vgs);
            elseif isfield(parsed,'gateVoltage') && ~isempty(parsed.gateVoltage)
                Vgs = mean(parsed.gateVoltage);
            else
                Vgs = 0;
            end
            
            if isfield(parsed,'filename_Vds') && isfinite(parsed.filename_Vds)
                Vds = parsed.filename_Vds;
            elseif isfield(parsed,'Vds') && ~isempty(parsed.Vds)
                Vds = mean(parsed.Vds);
            elseif isfield(parsed,'drainVoltage') && ~isempty(parsed.drainVoltage)
                Vds = mean(parsed.drainVoltage);
            else
                Vds = -0.1;
            end
            
            uc_val = obj.getUc(Vgs, Vds, data);
            
            t = parsed.time(:);
            Id = parsed.drainCurrent(:);
            valid = (t>0)&isfinite(t)&isfinite(Id);
            t = t(valid); Id = Id(valid);
            if numel(t)<50, result=obj.createFailedResult('Not enough data points'); return; end
            
            [t,ord]=sort(t,'ascend'); Id=Id(ord); [t,ia]=unique(t,'stable'); Id=Id(ia);
            if numel(t)<50, result=obj.createFailedResult('Not enough unique time points'); return; end
            
            t_fit = logspace(log10(min(t)),log10(max(t)),250)';
            Id_fit = interp1(t,Id,t_fit,'pchip','extrap');
            
            try
                [p_opt, fit_info] = obj.stagedFit(t_fit, Id_fit, Vgs, Vds, uc_val);
                [fit_curve, ~] = obj.evaluateFit(p_opt, t_fit, Vgs, Vds, uc_val);
                m = obj.computeFitMetrics(Id_fit, fit_curve);
                result = struct('f',p_opt(1),'tau_de',10^p_opt(2),'M0_fit',10^p_opt(3), ...
                    'I_off',p_opt(4),'R2',m.R2,'RMSE',m.RMSE,'NRMSE',m.NRMSE, ...
                    'success',true,'iterations',fit_info.iterations,'funcCount',fit_info.funcCount, ...
                    'Vgs',Vgs,'Vds',Vds);
            catch ME
                obj.logger.warn('Fit failed for file %d: %s', idx, ME.message);
                result = obj.createFailedResult(ME.message);
            end
        end
        
        function [p_opt, info] = stagedFit(obj, t, Id, Vgs, Vds, uc)
            P0 = obj.parameters.P0; 
            L = obj.parameters.L; 
            mu_p = obj.getHolesMobility(); 
            VT = obj.VT; 
            q = obj.parameters.q;

            % Stage 1: fit [log10(tau_d), f] with fixed M0
            lb1=[-9,0]; ub1=[5,1]; p01=[-2,0.5];
            obj_fun1 = @(p) obj.getObjective(p, t, Id, Vgs, Vds, uc, P0, L, mu_p, VT, q, true);
            [p1,~]=obj.runGlobalSearch(obj_fun1,lb1,ub1,p01);

            % Stage 2: fit [log10(M0), log10(tau_d), f]
            lb2=[10,p1(1),p1(2)]; ub2=[17,p1(1),p1(2)]; p02=[log10(P0),p1(1),p1(2)];
            obj_fun2 = @(p) obj.getObjective(p, t, Id, Vgs, Vds, uc, P0, L, mu_p, VT, q, false);
            [p2,info]=obj.runGlobalSearch(obj_fun2,lb2,ub2,p02);

            p_opt=[p2(3), p2(2), 10^p2(1), 0];

            % Stage 3: local refine full params [f,tau_d,M0,I_off]
            lb3=[0,p2(2)-0.5,10^(p2(1)-0.5),-1e-4]; 
            ub3=[1,p2(2)+0.5,10^(p2(1)+0.5), 1e-4];
            obj_fun3 = @(p) obj.getObjectiveFull(p, t, Id, Vgs, Vds, uc, P0, L, mu_p, VT, q);
            [p_opt,info]=obj.runLocalSearch(obj_fun3,lb3,ub3,p_opt);
        end
        
        function J = getObjective(obj,p,t,Id,Vgs,Vds,uc,P0,L,mu_p,VT,q,fixM0)
            r = obj.getResidual(obj.expandParams(p, fixM0), t, Id, Vgs, Vds, uc, P0, L, mu_p, VT, q);
            J = sum(r.^2);  % scalar objective for fmincon
        end
        
        function J = getObjectiveFull(obj,p,t,Id,Vgs,Vds,uc,P0,L,mu_p,VT,q)
            r = obj.getResidual(p, t, Id, Vgs, Vds, uc, P0, L, mu_p, VT, q);
            J = sum(r.^2);  % scalar objective for fmincon
        end
        
        function pfull = expandParams(obj, p, fixM0)
            if fixM0
                tau_d = 10^p(1); 
                f = p(2); 
                M0 = obj.parameters.M0; 
                I_off = 0;
            else
                M0 = 10^p(1); 
                tau_d = 10^p(2); 
                f = p(3); 
                I_off = 0;
            end
            pfull = [f, tau_d, M0, I_off];
        end
        
        function r = getResidual(~,p,t,Id,Vgs,Vds,uc,P0,L,mu_p,VT,q)
            Id_fit = computeFitStatic(p,t,Vgs,Vds,uc,P0,L,mu_p,VT,q);
            r=(Id_fit-Id)./(abs(Id)+1e-8);
        end
        
        function [Id_fit,M] = evaluateFit(obj,p,t,Vgs,Vds,uc)
            [Id_fit,M]=computeFitStatic(p,t,Vgs,Vds,uc,obj.parameters.P0,obj.parameters.L,obj.getHolesMobility(),obj.VT,obj.parameters.q);
        end
        
        function [p_opt,info]=runGlobalSearch(~,objf,lb,ub,x0)
            options=optimoptions('fmincon','Display','off','Algorithm','sqp');
            problem=createOptimProblem('fmincon','x0',x0,'objective',objf,'lb',lb,'ub',ub,'options',options);
            gs=GlobalSearch('Display','off','NumStageOnePoints',200,'NumTrialPoints',500);
            [p_opt,~,ef,out]=run(gs,problem);
            info.exitflag=ef; info.iterations=out.iterations; info.funcCount=out.funcCount;
        end
        
        function [p_opt,info]=runLocalSearch(~,objf,lb,ub,x0)
            options=optimoptions('fmincon','Display','off','Algorithm','sqp','MaxIterations',500,'MaxFunctionEvaluations',5000);
            [p_opt,~,ef,out]=fmincon(objf,x0,[],[],[],[],lb,ub,[],options);
            info.exitflag=ef; info.iterations=out.iterations; info.funcCount=out.funcCount;
        end
        
        function uc=getUc(obj,~,Vds,data)
            uc=obj.parameters.uc;
            if isfield(data,'steadyState') && isfield(data.steadyState,'parsed')
                p=data.steadyState.parsed;
                if isfield(p,'Vd_sorted') && isfield(p,'Id_matrix') && isfield(p,'Vg_sorted')
                    [~,idx]=min(abs(p.Vd_sorted-Vds));
                    if idx >=1 && idx <= size(p.Id_matrix,2)
                        gm=gradient(p.Id_matrix(:,idx),p.Vg_sorted);
                        [~,midx]=max(abs(gm)); uc=p.Vg_sorted(midx);
                    end
                end
            end
        end
        
        function parsed=getTransientRecord(~,data,idx)
            tr=data.transient;
            if isfield(tr,'parsed') && ~isempty(tr.parsed), parsed=tr.parsed{idx}; return; end
            if isfield(tr,'data') && ~isempty(tr.data), parsed=tr.data{idx}; return; end
            if isfield(tr,'files') && ~isempty(tr.files), parsed=tr.files{idx}; return; end
            if iscell(tr), parsed=tr{idx}; return; end
            error('OECT:TransientFormat','Unsupported transient format');
        end
        
        function n=getTransientCount(~,data)
            tr=data.transient;
            if isfield(tr,'filenames') && ~isempty(tr.filenames), n=numel(tr.filenames); return; end
            if isfield(tr,'parsed') && ~isempty(tr.parsed), n=numel(tr.parsed); return; end
            if isfield(tr,'data') && ~isempty(tr.data), n=numel(tr.data); return; end
            if isfield(tr,'files') && ~isempty(tr.files), n=numel(tr.files); return; end
            if iscell(tr), n=numel(tr); return; end
            error('OECT:TransientFormat','No transient records');
        end
        
        function result=createFailedResult(~,msg)
            result=struct('success',false,'error',msg,'R2',-Inf,'RMSE',Inf,'NRMSE',Inf);
        end
        
        function m=computeFitMetrics(~,y,yh)
            r=y-yh; 
            m.RMSE=sqrt(mean(r.^2)); 
            m.NRMSE=m.RMSE/(max(y)-min(y)+eps); 
            m.R2=1-sum(r.^2)/(sum((y-mean(y)).^2)+eps);
        end
        
        function fitResults=aggregateFits(obj,allResults)
            good=cellfun(@(r)isstruct(r)&&isfield(r,'success')&&r.success,allResults);
            idx=find(good); 
            fitResults=struct('n_total',numel(allResults),'n_success',numel(idx),'n_failed',numel(allResults)-numel(idx));
            if isempty(idx), fitResults.avgR2=-Inf; fitResults.parameters=obj.parameters; return; end
            f=cellfun(@(r)r.f,allResults(idx)); 
            td=cellfun(@(r)r.tau_de,allResults(idx)); 
            m0=cellfun(@(r)r.M0_fit,allResults(idx)); 
            r2=cellfun(@(r)r.R2,allResults(idx));
            fitResults.avg_f=median(f); 
            fitResults.avg_tau_de=median(td); 
            fitResults.avg_M0=median(m0); 
            fitResults.avgR2=median(r2);
            obj.parameters.params.f=fitResults.avg_f; 
            obj.parameters.params.tau_de=fitResults.avg_tau_de; 
            obj.parameters.params.M0=fitResults.avg_M0;
            fitResults.parameters=obj.parameters; 
            fitResults.all_results=allResults(idx); 
            fitResults.good_idx=idx;
        end
        
        % abstract API
        function name=getModelName(~), name='Bisquert'; end
        function d=getModelDescription(~), d='Bisquert ionic dynamics model for OECTs'; end
        function p=getParameterNames(~), p={'P0','M0','tau_de','f','uc','holes_mobility'}; end
        function b=getParameterBounds(~), b=struct('P0',[0,1e30],'M0',[0,1e30],'tau_de',[1e-6,100],'f',[0,1],'uc',[-5,5],'holes_mobility',[1e-6,1]); end
        function [Vg,Id,gm]=transferCharacteristics(obj,Vg_range,Vds_fixed)
            if nargin<2, Vg_range=linspace(-0.6,0.6,50); end
            if nargin<3, Vds_fixed=-0.2; end
            t=linspace(0,10*obj.parameters.tau_de,200); Id=zeros(size(Vg_range));
            for i=1:numel(Vg_range), s=obj.simulate(Vg_range(i)*ones(size(t)),t,Vds_fixed); Id(i)=s.Id(end); end
            Vg=Vg_range; gm=gradient(Id,Vg_range);
        end
        function [Vd,Id]=outputCharacteristics(obj,Vg_fixed,Vd_range)
            if nargin<2, Vg_fixed=-0.2; end
            if nargin<3, Vd_range=linspace(-0.6,0.6,40); end
            t=linspace(0,10*obj.parameters.tau_de,200); vg=Vg_fixed*ones(size(t)); Id=zeros(size(Vd_range));
            for i=1:numel(Vd_range), s=obj.simulate(vg,t,Vd_range(i)); Id(i)=s.Id(end); end
            Vd=Vd_range;
        end
    end
end

function [Id_fit,M] = computeFitStatic(p,t,Vgs,Vds,uc,P0,L,mu_p,VT,q)
    f=p(1); tau_d=p(2); M0=p(3); I_off=p(4);
    t = t(:); n=length(t);
    Id_fit=zeros(n,1); M=zeros(n,1);

    if ~isscalar(Vgs), Vgs = Vgs(1); end
    if ~isscalar(Vds), Vds = Vds(1); end

    vmag=max(abs(Vds),1e-6);
    tau_e=(L^2)/(mu_p*vmag);
    theta=sign(Vds); if theta==0, theta=1; end

    Meq=@(v) (2/3)*M0*(max(abs(v-uc)/VT,0))^(1.5);
    M(1)=Meq(Vgs);

    for i=1:n
        dt=0; if i>1, dt=t(i)-t(i-1); end
        dMdt=(Meq(Vgs)-M(i))/max(tau_d,1e-12);
        if i<n, M(i+1)=M(i)+dMdt*dt; end
        Id_fit(i)=theta*(q*L/tau_e)*max(P0-M(i),0)-q*L*f*dMdt+I_off;
    end
end