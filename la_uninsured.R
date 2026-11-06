library(tidycensus)
library(tidyverse)
library(sf)
library(mapgl)
library(htmlwidgets)
library(htmltools)

#Retrieve the census api
#census_api_key("bd5dbd98dca9df47af0126017c8e043d4dd246a7", install = TRUE)
#done from v1

#download the tract data
#number of uninsured people (S2701_C04_001)
# we need counts to build neighborhood totals.
  
la_raw <- get_acs(geography = "tract",
                      state = "CA",
                     county = "Los Angeles", 
                  variables = c( pct_uninsured = "S2701_C05_001",   # percent uninsured
                                     uninsured = "S2701_C04_001",   # number of people uninsured
                                    population = "S2701_C01_001"),  # population the rate is based o
                       year = 2024,
                     survey = "acs5",
                   geometry = TRUE, 
                     output = "wide")
  
#load the neighborhood boundaries from LA Times' Github page
hoods <- st_read("https://raw.githubusercontent.com/datadesk/mapping-la-data/main/geojson/la-county-neighborhoods-v6.geojson",
  quiet = TRUE) %>%
  select(neighborhood = name) %>%
  st_make_valid()
  
  
#match each tract to a neighborhood
#since tracts and neighborhoods dont line up perfectly, make it so that a tract belongs
#to the neighborhood that contains a point inside it
#we use st_point_on_surface() to pick that point
#2229 is a California map projection measured in ft. using it for accuracy and preference
  
tract_to_hood <- la_raw %>%
  st_transform(2229) %>%
  st_point_on_surface() %>%
  st_join(st_transform(hoods, 2229)) %>%
  st_drop_geometry() %>%
  distinct(GEOID, .keep_all = TRUE) %>%
  select(GEOID, neighborhood)
  
#check tracts that didnt land in any neighborhood
  sum(is.na(tract_to_hood$neighborhood))
  
  
#compare countrywide
county_rate <- sum(la_raw$uninsuredE, na.rm = TRUE) / sum(la_raw$populationE, na.rm = TRUE) * 100
county_rate
  
  
#hood totals
hood_stats <- la_raw %>%
  st_drop_geometry() %>%
  left_join(tract_to_hood, by = "GEOID") %>%
  filter(!is.na(neighborhood)) %>%
  group_by(neighborhood) %>%
  summarise(uninsured = sum(uninsuredE,  na.rm = TRUE),
           population = sum(populationE, na.rm = TRUE),
             n_tracts = n()) %>%

#blank out negligible hoods
mutate(pct_uninsured = if_else(population < 1000, NA_real_, uninsured / population * 100), 
       rank = min_rank(desc(pct_uninsured)))
#1 = highest uninsured rate
n_ranked <- sum(!is.na(hood_stats$pct_uninsured))
  
#top 10 hoods
hood_stats %>% arrange(rank) %>% head(10)
  
  
#hood map layer with hover
neighborhoods <- hoods %>%
  inner_join(hood_stats, by = "neighborhood") %>%
  mutate(diff = pct_uninsured - county_rate,
        hover = if_else(is.na(pct_uninsured), neighborhood,
                        paste0(neighborhood, ": ", round(pct_uninsured, 1), "%")),
        popup = if_else(is.na(pct_uninsured), paste0("<b>", neighborhood, "</b><br>Too few residents to estimate"),
                        paste0("<b style='font-size:15px'>", neighborhood, "</b><br>",
                               "<span style='font-size:22px'>", round(pct_uninsured, 1), "%</span>",
                               " without health insurance<br>", 
                               "About ", scales::comma(uninsured, accuracy = 10),
                               " of ", scales::comma(population),
                               " residents<br>", round(abs(diff), 1),
                               " points ", if_else(diff >= 0, "above", "below"),
                               " the county rate (", round(county_rate, 1), "%)<br>",
                               "<span style='color:#666'>", scales::ordinal(rank),
                               " highest of ", n_ranked, " neighborhoods</span>"))) %>%
  st_transform(4326)
  
  
#tract map layer
tracts <- la_raw %>%
  left_join(tract_to_hood, by = "GEOID") %>%
  mutate(pct_uninsured = if_else(populationE < 100, NA_real_, pct_uninsuredE),
         tract = str_extract(NAME, "Census Tract [0-9.]+"),
         place = coalesce(neighborhood, "LA County"),
         
  hover = if_else(is.na(pct_uninsured),
        paste0(place, " · ", tract),
        paste0(place, " · ", round(pct_uninsured, 1), "%")),
  
  popup = if_else(is.na(pct_uninsured),
        paste0("<b>", tract, "</b><br>", place, "<br>Too few residents to estimate"),
        paste0("<b>", tract, "</b><br>", place, "<br>", "<span style='font-size:20px'>",
          round(pct_uninsured, 1), "%</span>", " without health insurance<br>",
          "About ", scales::comma(uninsuredE, accuracy = 10),
          " of ", scales::comma(populationE), " residents<br>",
          "<span style='color:#666'>Margin of error: ±",
          round(pct_uninsuredM, 1), " points</span>"))) %>%
  select(GEOID, pct_uninsured, hover, popup) %>%
  st_transform(4326)
  
  
#building the map
#set up the map's color scale
#so this spreads the colors where the data actually is.
breaks <- c(0, 5, 10, 15, 20)
colors <- c("#f7fbff", "#c6dbef", "#6baed6", "#2171b5", "#08306b")
  
switch_zoom <- 12
  
map_uninsured <- maplibre(style = carto_style("positron"),
                         center = c(-118.30, 34.03), zoom = 9.5) %>%
  
#hoods (zoomed out)
add_fill_layer(id = "neighborhoods", source = neighborhoods, 
    fill_color = interpolate(column = "pct_uninsured", values = breaks, stops = colors, na_color = "#e5e5e5"),
    fill_opacity = 0.8, fill_outline_color = "#ffffff", tooltip = "hover", popup = "popup", hover_options = list(fill_opacity = 1),
    max_zoom = switch_zoom) %>%
#tracts (zoomed in)
add_fill_layer(id = "tracts", source = tracts,
    fill_color = interpolate(column = "pct_uninsured", values = breaks, stops = colors, na_color = "#e5e5e5"),
    fill_opacity = 0.75,fill_outline_color = "#ffffff", tooltip = "hover", popup = "popup", hover_options = list(fill_opacity = 1),
    min_zoom = switch_zoom) %>%

#neighborhood outlines on top of the tracts, helps with orientation
add_line_layer(id = "neighborhood_borders", source = neighborhoods,
    line_color = "#333333",
    line_width = 1,
    min_zoom = switch_zoom) %>%
add_legend(legend_title = "Residents without health insurance",
    values = c("0%", "5%", "10%", "15%", "20%+"),
    colors = colors,
      type = "continuous",
  position = "top-left",
     width = "180px") %>%

#zoom buttons
add_navigation_control()
  
  
#adding a title and source line
map_uninsured <- map_uninsured %>%
  prependContent(tags$div(style = "font-family: Helvetica, Arial, sans-serif; padding: 12px 4px 8px;",
                          tags$h2(style = "margin: 0 0 4px;", "Who lacks health insurance in Los Angeles County?"),
                          tags$p(style = "margin: 0; color: #555;",
                                 paste0("About ", round(county_rate, 1),
                                        "% of county residents have no health coverage. ",
                                        "Zoom in to see census tracts. Click any area for details.")))) %>%
  
  appendContent(tags$p(style = "font-family: Helvetica, Arial, sans-serif; font-size: 12px; color: #777; padding: 6px 4px;",
        "Source: U.S. Census Bureau, American Community Survey 2020–2024 5-year estimates (table S2701). ",
        "Neighborhoods: Los Angeles Times Mapping L.A. Each tract is assigned to the neighborhood containing ",
        "an interior point of the tract. Areas with too few residents for a reliable estimate are shown in grey."))

map_uninsured
  
  
#save it all
saveWidget(map_uninsured, "la_uninsured_map_v2.html", selfcontained = TRUE)
st_write(neighborhoods, "la_uninsured_neighborhoods.geojson", delete_dsn = TRUE)
write_csv(hood_stats, "la_uninsured_neighborhoods.csv")

county_rate                               # county rate for the Results paragraph
sum(la_raw$uninsuredE, na.rm = TRUE)      # number of uninsured people countywide
hood_stats %>% arrange(rank) %>% head(5) 
