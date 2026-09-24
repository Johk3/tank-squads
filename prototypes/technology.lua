data:extend{
  {
    type = "technology",
    name = "tank-squad-unlock",
    icon = "__base__/graphics/technology/military.png",
    icon_size = 256,
    effects = {
      {type = "unlock-recipe", recipe = "tank-squad-barracks"},
      {type = "unlock-recipe", recipe = "tank-squad-rally-flag"},
      {type = "unlock-recipe", recipe = "tank-squad-train-1"},
      {type = "unlock-recipe", recipe = "tank-squad-train-2"},
      {type = "unlock-recipe", recipe = "tank-squad-train-3"},
      {type = "unlock-recipe", recipe = "tank-squad-train-siege"},
      {type = "unlock-recipe", recipe = "tank-squad-train-flame"},
    },
    prerequisites = {"military-science-pack"},
    unit = {
      count = 100,
      ingredients = {
        {"automation-science-pack", 1},
        {"logistic-science-pack", 1},
        {"military-science-pack", 1},
      },
      time = 30,
    },
  },
}
