#!/usr/bin/env python3
"""
ETL CAR Detalhes: baixa shapefiles do SICAR via pacote SICAR e carrega no PostgreSQL (schema raw).

Uso:
  # Baixar todos os estados (tema padrão AREA_PROPERTY):
  python scripts/etl_car_detalhes.py --states all

  # Baixar estados específicos:
  python scripts/etl_car_detalhes.py --states SP RJ MG

  # Baixar temas específicos:
  python scripts/etl_car_detalhes.py --states SP --themes AREA_PROPERTY APPS
"""

import argparse
import json
import os
import subprocess
import tempfile
import time
import zipfile
from datetime import datetime
from pathlib import Path

from SICAR import Polygon, Sicar, State
from SICAR.drivers import Tesseract


def log(msg: str) -> None:
    ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


THEMES = {
    "AREA_PROPERTY": {"polygon": Polygon.AREA_PROPERTY, "dataset": "car_area_imovel", "enabled": True},
    "APPS": {"polygon": Polygon.APPS, "dataset": "car_area_preservacao_permanente", "enabled": False},
    "NATIVE_VEGETATION": {"polygon": Polygon.NATIVE_VEGETATION, "dataset": "car_remanescente_vegetacao_nativa", "enabled": False},
    "CONSOLIDATED_AREA": {"polygon": Polygon.CONSOLIDATED_AREA, "dataset": "car_area_consolidada", "enabled": False},
    "AREA_FALL": {"polygon": Polygon.AREA_FALL, "dataset": "car_area_pousio", "enabled": False},
    "HYDROGRAPHY": {"polygon": Polygon.HYDROGRAPHY, "dataset": "car_hidrografia", "enabled": False},
    "RESTRICTED_USE": {"polygon": Polygon.RESTRICTED_USE, "dataset": "car_uso_restrito", "enabled": False},
    "ADMINISTRATIVE_SERVICE": {"polygon": Polygon.ADMINISTRATIVE_SERVICE, "dataset": "car_servidao_administrativa", "enabled": False},
    "LEGAL_RESERVE": {"polygon": Polygon.LEGAL_RESERVE, "dataset": "car_reserva_legal", "enabled": False},
}


def load_env_file(env_path: Path) -> None:
    """Carrega .env do projeto sem sobrescrever variáveis já existentes no ambiente."""
    if not env_path.exists():
        return

    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def get_pg_config() -> dict:
    """Obtém configurações de conexão do PostgreSQL a partir do ambiente."""
    return {
        "host": os.getenv("PGHOST") or os.getenv("POSTGRES_HOST", "postgres_bdgeo"),
        "port": os.getenv("PGPORT") or os.getenv("POSTGRES_PORT", "5432"),
        "db": os.getenv("PGDATABASE") or os.getenv("POSTGRES_DB", "bdgeo_2026"),
        "user": os.getenv("PGUSER") or os.getenv("POSTGRES_USER", "super_user"),
        "password": os.getenv("PGPASSWORD") or os.getenv("POSTGRES_PASSWORD", "super_password"),
    }


def ensure_checkpoint_dir(base_dir: Path) -> Path:
    checkpoint_dir = base_dir / "checkpoints"
    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    return checkpoint_dir


def control_file_path(base_dir: Path) -> Path:
    checkpoint_dir = ensure_checkpoint_dir(base_dir)
    return checkpoint_dir / "car_release_control.json"


def load_control(path: Path) -> dict:
    if path.exists():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            log("Aviso: controle corrompido, recriando.")
    return {"last_run": None, "states": {}}


def save_control(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")


def needs_update(control: dict, uf: str, theme_key: str, release_date: str) -> bool:
    state_info = control.get("states", {}).get(uf, {})
    theme_info = state_info.get(theme_key)
    if not theme_info:
        return True
    return theme_info.get("release_date") != release_date


def resolve_states(raw_states: list[str] | None) -> list[State]:
    if not raw_states:
        return list(State)

    normalized = [item.strip().upper() for item in raw_states if item and item.strip()]
    if not normalized or normalized == ["ALL"]:
        return list(State)

    try:
        return [State(item) for item in normalized]
    except ValueError as exc:
        raise ValueError(f"UF inválida: {exc}") from exc


def find_first_shp(folder: Path) -> Path:
    shp_files = sorted(folder.rglob("*.shp"))
    if not shp_files:
        raise FileNotFoundError(f"Nenhum .shp encontrado em {folder}")
    return shp_files[0]


def run_ogr2ogr_to_postgres(
    input_shp: Path,
    table_name: str,
    pg_cfg: dict,
    schema: str = "raw",
    overwrite: bool = True,
) -> None:
    """Carrega o Shapefile diretamente no PostgreSQL usando ogr2ogr."""
    pg_conn = (
        f"PG:host={pg_cfg['host']} port={pg_cfg['port']} "
        f"dbname={pg_cfg['db']} user={pg_cfg['user']} password={pg_cfg['password']}"
    )
    flag = "-overwrite" if overwrite else "-append"

    cmd = [
        "ogr2ogr",
        flag,
        "-f", "PostgreSQL",
        pg_conn,
        str(input_shp),
        "-nln", f"{schema}.{table_name}",
        "-lco", "GEOMETRY_NAME=geom",
        "-lco", "PRECISION=NO",
        "-oo", "ADJUST_TYPE=YES",
        "-nlt", "PROMOTE_TO_MULTI",
        "-t_srs", "EPSG:4674",
        "-gt", "65536",
    ]
    subprocess.run(cmd, check=True)


def run_post_process_upsert(uf_code: str, pg_cfg: dict) -> None:
    """Dispara a procedure de upsert no schema analytics se existir para o tema car_area_imovel."""
    psql_conn = (
        f"host={pg_cfg['host']} port={pg_cfg['port']} "
        f"dbname={pg_cfg['db']} user={pg_cfg['user']} password={pg_cfg['password']}"
    )
    sql = f"CALL analytics.upsert_car_area_imovel('{uf_code.lower()}');"
    cmd = ["psql", psql_conn, "-v", "ON_ERROR_STOP=1", "-qAtc", sql]
    try:
        subprocess.run(cmd, check=True)
        log(f"Upsert em analytics.car_area_imovel concluído para UF={uf_code}.")
    except subprocess.CalledProcessError as err:
        log(f"Aviso: Falha ao executar upsert em analytics para {uf_code}: {err}")


def process_one(
    car: Sicar,
    uf: State,
    theme_key: str,
    theme_cfg: dict,
    release_dates: dict,
    control: dict,
    pg_cfg: dict,
    max_retries: int = 3,
    retry_delay: int = 10,
) -> bool:
    """Baixa via SICAR, extrai e envia direto ao PostgreSQL com retries."""
    uf_code = uf.value

    if uf not in release_dates:
        log(f"Aviso: UF {uf_code} sem data de release no SICAR. Pulando.")
        return False

    release_date = release_dates[uf]
    if not needs_update(control, uf_code, theme_key, release_date):
        log(f"Pulando {uf_code}/{theme_key}: já atualizado para release {release_date}.")
        return True

    dataset_name = theme_cfg["dataset"]
    polygon = theme_cfg["polygon"]
    target_table = f"{dataset_name}_{uf_code.lower()}"

    for attempt in range(1, max_retries + 1):
        try:
            with tempfile.TemporaryDirectory(prefix=f"car_{uf_code}_{theme_key}_") as tmp:
                tmp_dir = Path(tmp)
                zip_dir = tmp_dir / "zips"
                extract_dir = tmp_dir / "extract"
                zip_dir.mkdir(parents=True, exist_ok=True)
                extract_dir.mkdir(parents=True, exist_ok=True)

                log(f"Tentativa {attempt}/{max_retries} - Baixando {uf_code}/{theme_key} via SICAR...")
                zip_path = car.download_state(
                    state=uf,
                    polygon=polygon,
                    folder=zip_dir,
                    tries=25,
                    timeout=90,
                )
                if zip_path is None:
                    raise RuntimeError(f"Falha ao obter captcha/download para {uf_code}/{theme_key}.")

                zpath = Path(zip_path)
                if not zpath.exists() or not zipfile.is_zipfile(zpath):
                    raise RuntimeError(f"ZIP inválido ou incompleto em {zpath}")

                with zipfile.ZipFile(zpath, "r") as zf:
                    zf.extractall(extract_dir)

                shp = find_first_shp(extract_dir)
                log(f"Importando para PostgreSQL -> raw.{target_table}...")
                run_ogr2ogr_to_postgres(shp, target_table, pg_cfg, schema="raw", overwrite=True)

                # Se for o tema principal de área do imóvel, executa o upsert para analytics
                if theme_key == "AREA_PROPERTY":
                    run_post_process_upsert(uf_code, pg_cfg)

            control.setdefault("states", {}).setdefault(uf_code, {})
            control["states"][uf_code][theme_key] = {
                "release_date": release_date,
                "dataset": dataset_name,
                "table": f"raw.{target_table}",
                "updated_at": datetime.now().isoformat(),
            }
            return True

        except Exception as exc:
            log(f"Aviso: Falha na tentativa {attempt}/{max_retries} para {uf_code}/{theme_key}: {exc}")
            if attempt < max_retries:
                wait_time = retry_delay * attempt
                log(f"Aguardando {wait_time}s antes de tentar novamente...")
                time.sleep(wait_time)
            else:
                log(f"Erro: Esgotadas as {max_retries} tentativas para {uf_code}/{theme_key}.")
                return False

    return False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="ETL CAR via pacote SICAR + ogr2ogr -> PostgreSQL (raw schema)"
    )
    parser.add_argument(
        "--themes",
        nargs="*",
        default=None,
        help="Lista de temas do catálogo. Ex.: AREA_PROPERTY APPS",
    )
    parser.add_argument(
        "--states",
        nargs="*",
        default=None,
        help="Lista de UFs ou all. Ex.: --states all / --states AC PA MT",
    )
    parser.add_argument(
        "--country",
        action="store_true",
        help="Atalho para --states all",
    )
    parser.add_argument(
        "--max-retries",
        type=int,
        default=3,
        help="Número máximo de tentativas por UF/tema (default: 3)",
    )
    parser.add_argument(
        "--retry-delay",
        type=int,
        default=10,
        help="Tempo base em segundos de espera entre tentativas (default: 10s)",
    )
    return parser.parse_args()


def main() -> int:
    base_dir = Path(__file__).resolve().parent.parent

    load_env_file(base_dir / ".env")
    load_env_file(base_dir / ".env.example")
    pg_cfg = get_pg_config()

    args = parse_args()
    effective_states = ["ALL"] if args.country else args.states

    try:
        states = resolve_states(effective_states)
    except ValueError as exc:
        log(str(exc))
        return 1

    requested_themes = args.themes or [key for key, value in THEMES.items() if value["enabled"]]
    invalid_themes = [theme for theme in requested_themes if theme not in THEMES]
    if invalid_themes:
        log(f"Temas inválidos: {', '.join(invalid_themes)}")
        return 1

    ctrl_path = control_file_path(base_dir)
    control = load_control(ctrl_path)

    log("Inicializando cliente SICAR (Tesseract OCR)...")
    car = Sicar(driver=Tesseract)

    log("Obtendo datas de release atuais...")
    release_dates = car.get_release_dates()

    total = len(states) * len(requested_themes)
    ok = 0
    fail = 0
    step = 0

    log(f"Iniciando carga CAR no Postgres. total={total}, estados={len(states)}, temas={requested_themes}")
    for theme_key in requested_themes:
        theme_cfg = THEMES[theme_key]
        for uf in states:
            step += 1
            log(f"[{step}/{total}] {uf.value}/{theme_key}")
            success = process_one(
                car=car,
                uf=uf,
                theme_key=theme_key,
                theme_cfg=theme_cfg,
                release_dates=release_dates,
                control=control,
                pg_cfg=pg_cfg,
                max_retries=args.max_retries,
                retry_delay=args.retry_delay,
            )
            if success:
                ok += 1
                save_control(ctrl_path, control)
            else:
                fail += 1

    control["last_run"] = datetime.now().isoformat()
    save_control(ctrl_path, control)

    log(f"Finalizado. Sucesso={ok}, Falhas={fail}")
    return 0 if fail == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())