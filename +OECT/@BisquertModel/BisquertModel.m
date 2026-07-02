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
            mu = obj.parameters.getParameter('holes_mobility');
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
            Vgs = obj.getScalarField(parsed, {'filename_Vgs','Vgs','gateVoltage'}, 0);
            Vds = obj.getScalarField(parsed, {'filename_Vds','Vds','drainVoltage'}, -0.1);
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
                result = struct('f',p_opt(1),'tau_de',p_opt(2),'M0_fit',p_opt(3), ...
                    'I_off',p_opt(4),'R2',m.R2,'RMSE',m.RMSE,'NRMSE',m.NRMSE, ...
                    'success',true,'iterations',fit_info.iterations,'funcCount',fit_info.funcCount, ...
                    'Vgs',Vgs,'Vds',Vds);
            catch ME
                obj.logger.warn('Fit failed for file %d: %s', idx, ME.message);
                result = obj.createFailedResult(ME.message);
            end
        end
        
        function [p_opt, info] = stagedFit(obj, t, Id, Vgs, Vds, uc)
            P0 = obj.parameters.P0; L = obj.parameters.L; mu_p = obj.getHolesMobility(); VT = obj.VT; q = obj.parameters.q;

            lb1=[-9,0]; ub1=[5,1]; p01=[-2,0.5];
            [p1,~]=obj.runGlobalSearch(@(p)obj.obj1(p,t,Id,Vgs,Vds,uc,P0,L,mu_p,VT,q),lb1,ub1,p01);

            lb2=[10,-9,0]; ub2=[17,5,1]; p02=[log10(P0),p1(1),p1(2)];
            [p2,~]=obj.runGlobalSearch(@(p)obj.obj2(p,t,Id,Vgs,Vds,uc,P0,L,mu_p,VT,q),lb2,ub2,p02);

            p_start=[p2(3),10^p2(2),10^p2(1),0];
            lb3=[0,1e-9,1e10,-1e-4]; ub3=[1,1e5,1e20,1e-4];
            [p_opt,info]=obj.runLocalSearch(@(p)obj.objFull(p,t,Id,Vgs,Vds,uc,P0,L,mu_p,VT,q),lb3,ub3,p_start);
        end
        
        function J = obj1(obj,p,t,Id,Vgs,Vds,uc,P0,L,mu_p,VT,q)
            pfull=[p(2),10^p(1),obj.parameters.M0,0]; J=obj.sse(pfull,t,Id,Vgs,Vds,uc,P0,L,mu_p,VT,q);
        end
        function J = obj2(~,p,t,Id,Vgs,Vds,uc,P0,L,mu_p,VT,q)
            pfull=[p(3),10^p(2),10^p(1),0]; J=localSSE(pfull,t,Id,Vgs,Vds,uc,P0,L,mu_p,VT,q);
        end
        function J = objFull(~,p,t,Id,Vgs,Vds,uc,P0,L,mu_p,VT,q)
            J=localSSE(p,t,Id,Vgs,Vds,uc,P0,L,mu_p,VT,q);
        end
        function J = sse(~,p,t,Id,Vgs,Vds,uc,P0,L,mu_p,VT,q)
            J=localSSE(p,t,Id,Vgs,Vds,uc,P0,L,mu_p,VT,q);
        end
        
        function [Id_fit,M] = evaluateFit(obj,p,t,Vgs,Vds,uc)
            [Id_fit,M]=localComputeFit(p,t,Vgs,Vds,uc,obj.parameters.P0,obj.parameters.L,obj.getHolesMobility(),obj.VT,obj.parameters.q);
        end
        
        function [p_opt,info]=runGlobalSearch(~,objf,lb,ub,x0)
            options=optimoptions('fmincon','Display','off','Algorithm','sqp');
            problem=createOptimProblem('fmincon','x0',x0,'objective',objf,'lb',lb,'ub',ub,'options',options);
            gs=GlobalSearch('Display','off','NumStageOnePoints',200,'NumTrialPoints',500);
            [p_opt,~,ef,out]=run(gs,problem);
            info=struct('exitflag',ef,'iterations',safeField(out,{'iterations','localSolverTotalIterations','funccount'},0), ...
                              'funcCount',safeField(out,{'funcCount','funccount','localSolverTotalFuncCount'},0));
        end
        
        function [p_opt,info]=runLocalSearch(~,objf,lb,ub,x0)
            options=optimoptions('fmincon','Display','off','Algorithm','sqp','MaxIterations',500,'MaxFunctionEvaluations',5000);
            [p_opt,~,ef,out]=fmincon(objf,x0,[],[],[],[],lb,ub,[],options);
            info=struct('exitflag',ef,'iterations',safeField(out,{'iterations','funccount'},0), ...
                              'funcCount',safeField(out,{'funcCount','funccount'},0));
        end
        
        function uc=getUc(obj,~,Vds,data)
            uc=obj.parameters.uc;
            if isfield(data,'steadyState') && isfield(data.steadyState,'parsed')
                p=data.steadyState.parsed;
                if isfield(p,'Vd_sorted') && isfield(p,'Id_matrix') && isfield(p,'Vg_sorted')
                    [~,idx]=min(abs(p.Vd_sorted-Vds));
                    if idx>=1 && idx<=size(p.Id_matrix,2)
                        gm=gradient(p.Id_matrix(:,idx),p.Vg_sorted);
                        [~,midx]=max(abs(gm)); uc=p.Vg_sorted(midx);
                    end
                end
            end
        end
        
        function fitResults=aggregateFits(obj,allResults)
            good=cellfun(@(r)isstruct(r)&&isfield(r,'success')&&r.success,allResults);
            idx=find(good);
            fitResults=struct('n_total',numel(allResults),'n_success',numel(idx),'n_failed',numel(allResults)-numel(idx));
            if isempty(idx), fitResults.avgR2=-Inf; fitResults.parameters=obj.parameters; return; end
            
            f=cellfun(@(r)r.f,allResults(idx)); td=cellfun(@(r)r.tau_de,allResults(idx)); m0=cellfun(@(r)r.M0_fit,allResults(idx)); r2=cellfun(@(r)r.R2,allResults(idx));
            fitResults.avg_f=median(f); fitResults.avg_tau_de=median(td); fitResults.avg_M0=median(m0); fitResults.avgR2=median(r2);
            
            % IMPORTANT: use setter API (params is read-only at property level)
            obj.parameters.setParameter('f', fitResults.avg_f);
            obj.parameters.setParameter('tau_de', fitResults.avg_tau_de);
            obj.parameters.setParameter('M0', fitResults.avg_M0);
            
            fitResults.parameters=obj.parameters; fitResults.all_results=allResults(idx); fitResults.good_idx=idx;
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
            result=struct('success',false,'error',msg,'R2',-Inf,'RMSE',Inf,'NRMSE',Inf,'iterations',0,'funcCount',0);
        end
        
        function m=computeFitMetrics(~,y,yh)
            r=y-yh; m.RMSE=sqrt(mean(r.^2)); m.NRMSE=m.RMSE/(max(y)-min(y)+eps); m.R2=1-sum(r.^2)/(sum((y-mean(y)).^2)+eps);
        end
        
        function v=getScalarField(~,S,names,defaultVal)
            v=defaultVal;
            for i=1:numel(names)
                if isfield(S,names{i}) && ~isempty(S.(names{i}))
                    val=S.(names{i});
                    if isnumeric(val), v=mean(val(:)); return; end
                end
            end
        end
        
        function name=getModelName(~), name='Bisquert'; end
        function d=getModelDescription(~), d='Bisquert ionic dynamics model for OECTs'; end
        function p=getParameterNames(~), p={'P0','M0','tau_de','f','uc','holes_mobility'}; end
        function b=getParameterBounds(~), b=struct('P0',[0,1e30],'M0',[0,1e30],'tau_de',[1e-6,100],'f',[0,1],'uc',[-5,5],'holes_mobility',[1e-6,1]); end
    end
end

function J=localSSE(p,t,Id,Vgs,Vds,uc,P0,L,mu_p,VT,q)
    [Id_fit,~]=localComputeFit(p,t,Vgs,Vds,uc,P0,L,mu_p,VT,q);
    r=(Id_fit-Id)./(abs(Id)+1e-8);
    J=sum(r.^2);
end

function [Id_fit,M]=localComputeFit(p,t,Vgs,Vds,uc,P0,L,mu_p,VT,q)
    f=p(1); tau_d=p(2); M0=p(3); I_off=p(4);
    t=t(:); n=length(t); Id_fit=zeros(n,1); M=zeros(n,1);
    if ~isscalar(Vgs), Vgs=Vgs(1); end
    if ~isscalar(Vds), Vds=Vds(1); end
    vmag=max(abs(Vds),1e-6); tau_e=(L^2)/(mu_p*vmag); theta=sign(Vds); if theta==0, theta=1; end
    Meq=@(v) (2/3)*M0*(max(abs(v-uc)/VT,0))^(1.5); M(1)=Meq(Vgs);
    for i=1:n
        dt=0; if i>1, dt=t(i)-t(i-1); end
        dMdt=(Meq(Vgs)-M(i))/max(tau_d,1e-12);
        if i<n, M(i+1)=M(i)+dMdt*dt; end
        Id_fit(i)=theta*(q*L/tau_e)*max(P0-M(i),0)-q*L*f*dMdt+I_off;
    end
end

function val=safeField(S,names,defaultVal)
    val=defaultVal;
    if ~isstruct(S), return; end
    for i=1:numel(names)
        if isfield(S,names{i}) && ~isempty(S.(names{i})) && isnumeric(S.(names{i}))
            val=S.(names{i}); return;
        end
    end
end