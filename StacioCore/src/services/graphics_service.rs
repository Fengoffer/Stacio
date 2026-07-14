#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct X11ProbeInput {
    pub x11_adapter_path: Option<String>,
    pub display: Option<String>,
    pub xauth_present: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct GraphicsDiagnostic {
    pub available: bool,
    pub code: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct GraphicsAdapterConfig {
    pub adapter_path: Option<String>,
    pub host: String,
    pub port: u16,
    pub username: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct GraphicsLaunchConfig {
    pub adapter_path: String,
    pub arguments: Vec<String>,
}

pub fn x11_forwarding_arguments(enable_x11: bool, trusted: bool) -> Vec<String> {
    if !enable_x11 {
        return vec![];
    }

    if trusted {
        vec!["-X".to_string(), "-Y".to_string()]
    } else {
        vec!["-X".to_string()]
    }
}

pub fn build_vnc_launch_config(
    config: GraphicsAdapterConfig,
) -> Result<GraphicsLaunchConfig, GraphicsConfigError> {
    build_graphics_launch_config(config)
}

fn build_graphics_launch_config(
    config: GraphicsAdapterConfig,
) -> Result<GraphicsLaunchConfig, GraphicsConfigError> {
    let endpoint = validated_endpoint(&config)?;
    Ok(GraphicsLaunchConfig {
        adapter_path: validated_adapter_path(config.adapter_path)?,
        arguments: vec![endpoint],
    })
}

fn validated_adapter_path(adapter_path: Option<String>) -> Result<String, GraphicsConfigError> {
    let adapter_path = adapter_path.unwrap_or_default();
    if adapter_path.trim().is_empty() {
        return Err(GraphicsConfigError::AdapterMissing);
    }
    Ok(adapter_path)
}

fn validated_endpoint(config: &GraphicsAdapterConfig) -> Result<String, GraphicsConfigError> {
    if config.host.trim().is_empty() || config.port == 0 {
        return Err(GraphicsConfigError::InvalidEndpoint);
    }
    Ok(format!("{}:{}", config.host.trim(), config.port))
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum GraphicsConfigError {
    #[error("缺少 Stacio 内置图形适配器")]
    AdapterMissing,
    #[error("图形会话端点无效")]
    InvalidEndpoint,
}

pub fn diagnose_x11(input: X11ProbeInput) -> GraphicsDiagnostic {
    if input.x11_adapter_path.as_deref().unwrap_or("").is_empty() {
        return GraphicsDiagnostic {
            available: false,
            code: "X11_ADAPTER_MISSING".to_string(),
            message: "缺少 Stacio 内置 X11 适配器".to_string(),
        };
    }

    if input.display.as_deref().unwrap_or("").is_empty() {
        return GraphicsDiagnostic {
            available: false,
            code: "X11_DISPLAY_MISSING".to_string(),
            message: "未配置 DISPLAY 环境变量".to_string(),
        };
    }

    if !input.xauth_present {
        return GraphicsDiagnostic {
            available: false,
            code: "X11_XAUTH_MISSING".to_string(),
            message: "缺少 xauth 授权数据".to_string(),
        };
    }

    GraphicsDiagnostic {
        available: true,
        code: "X11_READY".to_string(),
        message: "X11 转发诊断通过".to_string(),
    }
}
