import fnmatch
import pathlib
import zipfile


if __name__ == "__main__":
    repo_root = pathlib.Path(__file__).parent.parent.absolute()
    archive_path = repo_root / "FS25_AutoDrive.zip"
    gitignore_path = repo_root / ".gitignore"

    ignored = ["/.git", "/tools", "/credits.txt", "/.gitignore"]
    if gitignore_path.exists():
        ignored.extend(gitignore_path.read_text().splitlines())

    ignored = [x_clean for x in ignored if (x_clean := x.split("#")[0].strip())]

    if archive_path.exists():
        archive_path.unlink()

    # Create the archive
    with zipfile.ZipFile(archive_path, "w", zipfile.ZIP_DEFLATED) as zf:
        # Add all files in the repository
        for file in repo_root.rglob("*"):
            if not file.is_file():
                continue
            path_str = f"/{file.relative_to(repo_root)}"
            for line in ignored:
                if fnmatch.fnmatch(path_str, line):
                    break
                if fnmatch.fnmatch(path_str, f"{line}/*"):
                    break
            else:
                zf.write(file, file.relative_to(repo_root))
