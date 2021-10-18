NAMESPACE.ClientWrapper = function(config) 
{
    this.w_host = config['grpc_host'];
    this.w_port = config['grpc_port'];
    this.w_certificate = config['grpc_certificate'];
    
    this.w_secure = config['grpc_secure'];

    if(this.w_certificate){
        this.w_credentials['grpc_certificate'] = this.w_certificate;
    }

    //ClientOptions:: suppressCorsPreflight: boolean, withCredentials: boolean, this.unaryInterceptors; this.streamInterceptors; this.format; this.workerScope; this.useFetchDownloadStreams;
    if(this.w_credentials && Object.keys(this.w_credentials).length > 0){
        this.w_options['withCredentials'] = true;
    }
    if(config && config['options']){
        Object.assign(this.w_options, config['options']);
    }

    this.w_hostport = this.w_host + ':' + this.w_port;
    return NAMESPACE.Client.call(this, this.w_hostport, this.w_credentials, this.w_options);
};