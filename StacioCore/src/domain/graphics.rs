#[cfg(test)]
mod graphics_x11_tests {
    use crate::services::graphics_service::{
        diagnose_x11, x11_forwarding_arguments, X11ProbeInput,
    };

    #[test]
    fn builds_x11_forwarding_arguments() {
        let args = x11_forwarding_arguments(true, true);

        assert_eq!(args, vec!["-X".to_string(), "-Y".to_string()]);
    }

    #[test]
    fn diagnoses_available_x11_stack() {
        let diagnostic = diagnose_x11(X11ProbeInput {
            x11_adapter_path: Some("/Applications/Stacio.app/Contents/Adapters/x11".to_string()),
            display: Some(":0".to_string()),
            xauth_present: true,
        });

        assert!(diagnostic.available);
        assert_eq!(diagnostic.code, "X11_READY");
        assert_eq!(diagnostic.message, "X11 转发诊断通过");
    }

    #[test]
    fn diagnoses_missing_display() {
        let diagnostic = diagnose_x11(X11ProbeInput {
            x11_adapter_path: Some("/Applications/Stacio.app/Contents/Adapters/x11".to_string()),
            display: None,
            xauth_present: true,
        });

        assert!(!diagnostic.available);
        assert_eq!(diagnostic.code, "X11_DISPLAY_MISSING");
        assert_eq!(diagnostic.message, "未配置 DISPLAY 环境变量");
    }

    #[test]
    fn diagnoses_missing_x11_adapter_and_xauth_in_chinese() {
        let missing_adapter = diagnose_x11(X11ProbeInput {
            x11_adapter_path: None,
            display: Some(":0".to_string()),
            xauth_present: true,
        });
        let missing_xauth = diagnose_x11(X11ProbeInput {
            x11_adapter_path: Some("/Applications/Stacio.app/Contents/Adapters/x11".to_string()),
            display: Some(":0".to_string()),
            xauth_present: false,
        });

        assert_eq!(missing_adapter.message, "缺少 Stacio 内置 X11 适配器");
        assert_eq!(missing_xauth.message, "缺少 xauth 授权数据");
    }
}

#[cfg(test)]
mod graphics_adapter_tests {
    use crate::services::graphics_service::{
        build_vnc_launch_config, GraphicsAdapterConfig, GraphicsConfigError,
    };

    #[test]
    fn graphics_config_errors_use_chinese_user_facing_messages() {
        let error = build_vnc_launch_config(GraphicsAdapterConfig {
            adapter_path: Some("/Applications/Stacio.app/Contents/Adapters/vnc".to_string()),
            host: " ".to_string(),
            port: 5900,
            username: None,
        })
        .expect_err("invalid endpoint");

        assert_eq!(error, GraphicsConfigError::InvalidEndpoint);
        assert_eq!(error.to_string(), "图形会话端点无效");
    }

    #[test]
    fn builds_vnc_launch_config() {
        let config = build_vnc_launch_config(GraphicsAdapterConfig {
            adapter_path: Some("/Applications/Stacio.app/Contents/Adapters/vnc".to_string()),
            host: "vnc.example.com".to_string(),
            port: 5900,
            username: Some("ignored".to_string()),
        })
        .expect("vnc config");

        assert_eq!(config.arguments, vec!["vnc.example.com:5900".to_string()]);
    }
}
