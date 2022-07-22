export default class ClientWrapper extends Client {
    w_host = null;
    w_port = null;
    w_secure = null;
    w_hostport = null;

    w_certificate = null;
    w_credentials = {};
    w_options = {}

    constructor(config){
        this.w_host = config['grpc_host'];
        this.w_port = config['grpc_port'];
        this.w_certificate = config['grpc_certificate'];
        
        this.w_secure = config['grpc_secure'];

        if(this.w_certificate){
            this.w_credentials['grpc_certificate'] = this.w_certificate;
        }

        //ClientOptions:: suppressCorsPreflight: boolean, withCredentials: boolean, this.unaryInterceptors; this.streamInterceptors; this.format; this.workerScope; this.useFetchDownloadStreams;
        if(Object.keys(this.w_credentials).length > 0){
            this.w_options['withCredentials'] = true;
        }
        Object.assign(this.w_options, config['options'])

        this.w_hostport = hostName + ":" + port;
        super(this.w_hostport, this.w_credentials, options)
    }
}