use std::{fs, path::Path, process};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("Usage: iac-verify <backend> <dir>");
        eprintln!("Backends: go, helm, ansible, crossplane, pulumi");
        process::exit(1);
    }

    let backend = &args[1];
    let dir = Path::new(&args[2]);

    if !dir.exists() {
        eprintln!("FAIL: directory does not exist: {}", dir.display());
        process::exit(1);
    }

    let result = match backend.as_str() {
        "go" => verify_go(dir),
        "helm" => verify_helm(dir),
        "ansible" => verify_ansible(dir),
        "crossplane" => verify_crossplane(dir),
        "pulumi" => verify_pulumi(dir),
        other => {
            eprintln!("Unknown backend: {other}");
            process::exit(1);
        }
    };

    match result {
        Ok(report) => println!("{report}"),
        Err(e) => {
            eprintln!("FAIL: {e}");
            process::exit(1);
        }
    }
}

// ---------------------------------------------------------------------------
// Directory traversal
// ---------------------------------------------------------------------------

fn walk_files(dir: &Path, ext: &str) -> Vec<std::path::PathBuf> {
    let mut files = Vec::new();
    walk_recursive(dir, ext, &mut files);
    files.sort();
    files
}

fn walk_recursive(dir: &Path, ext: &str, out: &mut Vec<std::path::PathBuf>) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            let name = path.file_name().unwrap_or_default();
            if name != ".git" && name != ".github" {
                walk_recursive(&path, ext, out);
            }
        } else if path.extension().is_some_and(|e| e == ext) {
            out.push(path);
        }
    }
}

// ---------------------------------------------------------------------------
// Go backend (terraform, steampipe)
// ---------------------------------------------------------------------------

fn verify_go(dir: &Path) -> Result<String, String> {
    let files = walk_files(dir, "go");
    if files.is_empty() {
        return Err("no Go files found".into());
    }

    let mut errors = Vec::new();
    for f in &files {
        if let Err(e) = fs::read_to_string(f) {
            errors.push(format!("{}: {e}", f.display()));
        }
    }

    if !errors.is_empty() {
        return Err(format!(
            "{} file(s) with read errors:\n{}",
            errors.len(),
            errors.join("\n")
        ));
    }

    Ok(format!("{} Go files verified", files.len()))
}

// ---------------------------------------------------------------------------
// Helm backend
// ---------------------------------------------------------------------------

fn verify_helm(dir: &Path) -> Result<String, String> {
    let chart_yamls: Vec<_> = walk_files(dir, "yaml")
        .into_iter()
        .filter(|p| p.file_name().is_some_and(|n| n == "Chart.yaml"))
        .collect();

    if chart_yamls.is_empty() {
        return Err("no Chart.yaml files found".into());
    }

    let mut errors = Vec::new();

    for chart_yaml in &chart_yamls {
        let content = fs::read_to_string(chart_yaml)
            .map_err(|e| format!("{}: {e}", chart_yaml.display()))?;

        let doc: serde_yaml::Value = serde_yaml::from_str(&content)
            .map_err(|e| format!("{}: {e}", chart_yaml.display()))?;

        let Some(map) = doc.as_mapping() else {
            errors.push(format!("{}: not a YAML mapping", chart_yaml.display()));
            continue;
        };

        for field in ["apiVersion", "name", "version"] {
            let key = serde_yaml::Value::String(field.into());
            if !map.contains_key(&key) {
                errors.push(format!(
                    "{}: missing required field '{field}'",
                    chart_yaml.display()
                ));
            }
        }

        // Validate values.yaml if present
        if let Some(chart_dir) = chart_yaml.parent() {
            let values_path = chart_dir.join("values.yaml");
            if values_path.exists() {
                let values_content = fs::read_to_string(&values_path)
                    .map_err(|e| format!("{}: {e}", values_path.display()))?;
                let _: serde_yaml::Value = serde_yaml::from_str(&values_content)
                    .map_err(|e| format!("{}: {e}", values_path.display()))?;
            }
        }
    }

    if !errors.is_empty() {
        return Err(errors.join("\n"));
    }

    Ok(format!("{} Helm charts verified", chart_yamls.len()))
}

// ---------------------------------------------------------------------------
// Ansible backend
// ---------------------------------------------------------------------------

fn verify_ansible(dir: &Path) -> Result<String, String> {
    let files = walk_files(dir, "py");
    if files.is_empty() {
        return Err("no Python files found".into());
    }

    let mut errors = Vec::new();
    for f in &files {
        if let Err(e) = fs::read_to_string(f) {
            errors.push(format!("{}: {e}", f.display()));
        }
    }

    if !errors.is_empty() {
        return Err(format!(
            "{} file(s) with read errors:\n{}",
            errors.len(),
            errors.join("\n")
        ));
    }

    Ok(format!("{} Python files verified", files.len()))
}

// ---------------------------------------------------------------------------
// Crossplane backend
// ---------------------------------------------------------------------------

fn verify_crossplane(dir: &Path) -> Result<String, String> {
    let files = walk_files(dir, "yaml");
    if files.is_empty() {
        return Err("no YAML files found".into());
    }

    let mut errors = Vec::new();
    let mut crd_count: usize = 0;

    for f in &files {
        let content = fs::read_to_string(f)
            .map_err(|e| format!("{}: {e}", f.display()))?;

        let doc: serde_yaml::Value = serde_yaml::from_str(&content)
            .map_err(|e| format!("{}: {e}", f.display()))?;

        let Some(map) = doc.as_mapping() else {
            errors.push(format!("{}: not a YAML mapping", f.display()));
            continue;
        };

        let kind_key = serde_yaml::Value::String("kind".into());
        let kind = map
            .get(&kind_key)
            .and_then(serde_yaml::Value::as_str)
            .unwrap_or_default();

        if kind == "CustomResourceDefinition" {
            crd_count += 1;
            let spec_key = serde_yaml::Value::String("spec".into());
            let Some(serde_yaml::Value::Mapping(spec)) = map.get(&spec_key) else {
                errors.push(format!("{}: CRD missing spec", f.display()));
                continue;
            };
            let group_key = serde_yaml::Value::String("group".into());
            let names_key = serde_yaml::Value::String("names".into());

            if !spec.contains_key(&group_key) {
                errors.push(format!("{}: CRD missing spec.group", f.display()));
            }
            if !spec.contains_key(&names_key) {
                errors.push(format!("{}: CRD missing spec.names", f.display()));
            }
        }
    }

    if !errors.is_empty() {
        return Err(errors.join("\n"));
    }

    Ok(format!(
        "{} YAML files verified ({crd_count} CRDs)",
        files.len()
    ))
}

// ---------------------------------------------------------------------------
// Pulumi backend
// ---------------------------------------------------------------------------

fn verify_pulumi(dir: &Path) -> Result<String, String> {
    let files = walk_files(dir, "json");
    if files.is_empty() {
        return Err("no JSON files found".into());
    }

    let mut errors = Vec::new();

    for f in &files {
        let content = fs::read_to_string(f)
            .map_err(|e| format!("{}: {e}", f.display()))?;
        let _: serde_json::Value = serde_json::from_str(&content)
            .map_err(|e| format!("{}: {e}", f.display()))?;
    }

    // Validate schema.json structure
    let schema_path = dir.join("schema.json");
    if schema_path.exists() {
        let content = fs::read_to_string(&schema_path)
            .map_err(|e| format!("schema.json: {e}"))?;
        let doc: serde_json::Value =
            serde_json::from_str(&content).map_err(|e| format!("schema.json: {e}"))?;

        for field in ["name", "version", "resources"] {
            if doc.get(field).is_none() {
                errors.push(format!("schema.json: missing required field '{field}'"));
            }
        }
    }

    if !errors.is_empty() {
        return Err(errors.join("\n"));
    }

    Ok(format!("{} JSON files verified", files.len()))
}
