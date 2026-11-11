"""功能图标唯一几何入口；轮廓由等宽中线生成，语义实心标保留。"""
from ink.geometry import Layer
from . import actions, base, projects, statuses
from .shared import WIDTH, contours

BUILDERS = {}
for module in (base, actions, statuses, projects):
    assert not set(module.NAMES) & BUILDERS.keys(), f"Duplicate icon in {module.__name__}"
    BUILDERS.update({name: module for name in module.NAMES})


def centerlines(name):
    return BUILDERS[name].centerlines(name)


def draw(name, weight):
    module, width = BUILDERS[name], WIDTH[weight]
    ink = contours(*module.centerlines(name), width) + module.fills(name, width)
    return module.layers(name, width, ink) if module is statuses else [Layer("ink", ink)]
