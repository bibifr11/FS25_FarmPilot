# Script to synchronize and format translation files. This uses the english translation as a template.
# Missing entries will be added with the english text, invalid entries will be removed.
# The item order will also be updated to match the english translation.
#
# Usage: run the script, no parameters
# Requirements: modern Python (tested with 3.11), no external dependencies
# Error handling: none! If something goes wrong, you'll have to fix it manually.
# Note: always check the output files before committing.
# This is a tool and should not be included in the mod itself.

import os
import pathlib
import xml.etree.ElementTree as ET


def sync_translation(tr_file: pathlib.Path, default_values: dict[str, str]):
    tree = ET.parse(tr_file)
    root = tree.getroot()
    values = {item.get("name"): item.get("text") for item in root.find("texts")}

    for tr_name in list(values.keys()):
        if tr_name not in default_values:
            print(f"Removing invalid translation entry '{tr_name}' in {tr_file.name}")
            del values[tr_name]

    for tr_name, tr_text in default_values.items():
        if tr_name not in values:
            print(f"Adding missing translation entry '{tr_name}' in {tr_file.name}")
            values[tr_name] = tr_text

    # We want to manually format this section
    tab = "\t"
    root.remove(root.find("texts"))
    root.append(ET.Element("texts"))
    max_name_length = max(len(name) for name in values.keys())

    def format_item(name):
        spacing = "\t" * ((max_name_length - len(name)) // 4 + 1)
        value = values[name]
        line = f'\t\t<text name="{name}"{spacing}text="{value}" />'
        if name == "ad_color_singleConnection":
            line = "\t\t<!-- Please keep the numbers in the translation texts - they are used to sort / group the entries in the list -->\n" + line
        return line

    texts_str = "\n".join(format_item(name) for name in default_values.keys())
    
    # Output the file, replace the texts section, write the file
    ET.indent(tree, space=tab, level=0)
    content = ET.tostring(root, encoding="unicode", xml_declaration=True)
    content = content.replace("<texts />", f"<texts>\n{texts_str}\n{tab}</texts>")
    tr_file.write_text(content, encoding="utf-8")
    

def sync_all(working_dir: pathlib.Path):
    # Read the English translation file
    en_file = working_dir / "translation_en.xml"
    tree = ET.parse(en_file)
    values = {item.get("name"): item.get("text") for item in tree.getroot().find("texts")}
    for tr_file in working_dir.glob("translation_*.xml"):
        sync_translation(tr_file, values)


if __name__ == "__main__":
    working_dir = pathlib.Path(__file__).parent.parent.absolute() / "translations"
    sync_all(working_dir)
