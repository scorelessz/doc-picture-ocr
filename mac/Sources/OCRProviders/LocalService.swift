// Ollama、LM Studio、mlx-vlm、llama-server 这类本机服务（只连 127.0.0.1 / localhost）。
// App 和命令行共用同一个钥匙串条目。

public enum LocalService {
    /// 钥匙串条目名。服务开了鉴权（LM Studio 的 API Token、llama-server --api-key）才需要填
    public static let keyID = "local-service"
}
