
markdown <- function(text, tag = NULL, sections = FALSE) {
  tryCatch(
    expanded_text <- markdown_pass1(text),
    error = function(e) {
      message <- paste0(
        if (!is.na(tag$file)) paste0("[", tag$file, ":", tag$line, "] "),
        "@", tag$tag, " in inline code: ", e$message
      )
      stop(message, call. = FALSE)
    }
  )
  markdown_pass2(expanded_text, tag = tag, sections = sections)
}

#' Expand the embedded inline code
#'
#' For example this becomes two: `r 1+1`.
#' Variables can be set and then reused, within the same
#' tag: `r x <- 100; NULL`
#' The value of `x` is `r x`.
#'
#' We have access to the internal functions of the package, e.g.
#' since this is _roxygen2_, we can refer to the internal `markdown`
#' function, and this is `TRUE`: `r is.function(markdown)`.
#'
#' To insert the name of the current package: `r packageName()`.
#'
#' The `iris` data set has `r ncol(iris)` columns:
#' `r paste0("``", colnames(iris), "``", collapse = ", ")`.
#'
#' @param text Input text.
#' @return Text with the inline code expanded. A character vector of the
#' same length as the input `text`.
#'
#' @importFrom xml2 xml_ns_strip xml_find_all xml_attr
#' @importFrom purrr keep
#'
#' @keywords internal

markdown_pass1 <- function(text) {
  text <- paste(text, collapse = "\n")
  esc_text <- escape_rd_for_md(text)
  mdxml <- xml_ns_strip(md_to_mdxml(esc_text, sourcepos = TRUE))
  code_nodes <- xml_find_all(mdxml, ".//code")
  rcode_nodes <- keep(code_nodes, ~ str_sub(xml_text(.), 1, 2) == "r ")
  if (length(rcode_nodes) == 0) return(esc_text)
  code_text <- str_replace(map_chr(rcode_nodes, xml_text), "^r ", "")
  code_pos <- parse_md_pos(map_chr(rcode_nodes, xml_attr, "sourcepos"))
  out <- eval_code_nodes(code_text)
  str_set_all_pos(esc_text, code_pos, out)
}

parse_md_pos <- function(text) {
  nums <- map(strsplit(text, "[:-]"), as.integer)
  data.frame(
    start_line = map_int(nums, 1),
    start_column = map_int(nums, 2),
    end_line = map_int(nums, 3),
    end_column = map_int(nums, 4)
  )
}

eval_code_nodes <- function(text) {
  evalenv <- roxy_meta_get("evalenv")
  # This should only happen in our test cases
  if (is.null(evalenv)) evalenv <- new.env(parent = baseenv())
  map_chr(
    text,
    ~ paste(eval(parse(text = .), envir = evalenv), collapse = "\n")
  )
}

str_set_all_pos <- function(text, pos, value) {
  # Cmark has a bug when reporting source positions for multi-line
  # code tags, and it does not count the indenting space in the
  # continuation lines. However, the bug might get fixed later, so
  # for now we just simply error for multi-line inline code.
  if (any(pos$start_line != pos$end_line)) {
    stop("multi-line `r ` markup is not supported")
  }

  # Need to split the string, because of the potential multi-line
  # code tags, and then also recode the positions
  lens <- nchar(str_split(text, fixed("\n"))[[1]])
  shifts <- c(0, cumsum(lens + 1L))
  shifts <- shifts[-length(shifts)]
  start <- shifts[pos$start_line] + pos$start_column
  end <- shifts[pos$end_line] + pos$end_column

  # Create intervals for the parts we keep
  keep_start <- c(1, end + 2L)
  keep_end <- c(start - 2L, nchar(text))

  # Now piece them together
  out <- paste0(
    substring(text, keep_start, keep_end),
    c(value, ""),
    collapse = ""
  )
  attributes(out) <- attributes(text)
  out
}

markdown_pass2 <- function(text, tag = NULL, sections = FALSE) {
  esc_text_linkrefs <- add_linkrefs_to_md(text)

  mdxml <- md_to_mdxml(esc_text_linkrefs)
  state <- new.env(parent = emptyenv())
  state$tag <- tag
  state$has_sections <- sections
  rd <- mdxml_children_to_rd_top(mdxml, state)

  map_chr(rd, unescape_rd_for_md, text)
}

md_to_mdxml <- function(x, ...) {
  md <- commonmark::markdown_xml(x, hardbreaks = TRUE, extensions = "table", ...)
  xml2::read_xml(md)
}

mdxml_children_to_rd_top <- function(xml, state) {
  state$section_tag <- uuid()
  out <- map_chr(xml_children(xml), mdxml_node_to_rd, state)
  out <- c(out, mdxml_close_sections(state))
  rd <- paste0(out, collapse = "")
  secs <- strsplit(rd, state$section_tag, fixed = TRUE)[[1]]
  if (length(secs) == 0) secs <- ""
  str_trim(secs)
}

mdxml_children_to_rd <- function(xml, state) {
  out <- map_chr(xml_children(xml), mdxml_node_to_rd, state)
  paste0(out, collapse = "")
}

#' @importFrom xml2 xml_name xml_type xml_text xml_contents xml_attr xml_children xml_find_all
mdxml_node_to_rd <- function(xml, state) {
  if (!inherits(xml, "xml_node") ||
      ! xml_type(xml) %in% c("text", "element")) {
    roxy_tag_warning(state$tag, "Internal markdown translation failure")
    return("")
  }

  switch(xml_name(xml),
    html = ,
    document = ,
    unknown = mdxml_children_to_rd(xml, state),

    paragraph = paste0("\n\n", mdxml_children_to_rd(xml, state)),
    text = escape_comment(xml_text(xml)),
    emph = paste0("\\emph{", mdxml_children_to_rd(xml, state), "}"),
    strong = paste0("\\strong{", mdxml_children_to_rd(xml, state), "}"),
    softbreak = mdxml_break(state),
    linebreak = mdxml_break(state),

    code = mdxml_code(xml, state),
    code_block = mdxml_code_block(xml, state),

    table = mdxml_table(xml, state),
    list = mdxml_list(xml, state),
    item = mdxml_item(xml, state),
    link = mdxml_link(xml, state),
    image = mdxml_image(xml),
    heading = mdxml_heading(xml, state),

    # Only supported when including Rmds
    html_block = mdxml_html_block(xml, state),
    html_inline = mdxml_html_inline(xml, state),

    # Not supported
    block_quote = mdxml_unsupported(xml, state$tag, "block quotes"),
    hrule = mdxml_unsupported(xml, state$tag, "horizontal rules"),
    mdxml_unknown(xml, state$tag)
  )
}

mdxml_unknown <- function(xml, tag) {
  roxy_tag_warning(tag, "Unknown xml node: ", xml_name(xml))
  escape_comment(xml_text(xml))
}
mdxml_unsupported <- function(xml, tag, feature) {
  roxy_tag_warning(tag, "Use of ", feature, " is not currently supported")
  escape_comment(xml_text(xml))
}

mdxml_break <- function(state) {
  if (isTRUE(state$inlink)) " " else "\n"
}

mdxml_code <- function(xml, tag) {
  code <- xml_text(xml)

  # See escaping details at
  # https://cran.rstudio.com/doc/manuals/r-devel/R-exts.html#Insertions
  if (can_parse(code) || code %in% special) {
    paste0("\\code{", gsub("%", "\\\\%", code), "}")
  } else {
    paste0("\\verb{", escape_verb(code), "}")
  }
}

special <- c(
  "-", ":", "::", ":::", "!", "!=", "(", "[", "[[", "@",
  "*", "/", "&", "&&", "%*%", "%/%", "%%", "%in%", "%o%", "%x%",
  "^", "+", "<", "<=", "=", "==", ">", ">=", "|", "||", "~", "$",
  "for", "function", "if", "repeat", "while"
)

mdxml_code_block <- function(xml, state) {
  info <- xml_attr(xml, "info")[1]
  if (is.na(info) || nchar(info[1]) == 0) info <- NA_character_
  paste0(
    if (!is.na(info)) paste0("\\if{html}{\\out{<div class=\"", info, "\">}}"),
    "\\preformatted{",
    escape_verb(xml_text(xml)),
    "}",
    if (!is.na(info)) "\\if{html}{\\out{</div>}}"
  )
}

can_parse <- function(x) {
  tryCatch({
    parse_expr(x)
    TRUE
  }, error = function(x) FALSE)
}

escape_verb <- function(x) {
  # Don't need to escape \\ because that's already handled in double_escape_md()
  x <- gsub("%", "\\%", x, fixed = TRUE)
  x <- gsub("{", "\\{", x, fixed = TRUE)
  x <- gsub("}", "\\}", x, fixed = TRUE)
  x
}

mdxml_table <- function(xml, state) {
  head <- xml_children(xml)[[1]]
  align <- substr(xml_attr(xml_children(head), "align", default = "left"), 1, 1)

  rows <- xml_find_all(xml, "d1:table_row|d1:table_header")
  cells <- map(rows, xml_find_all, "d1:table_cell")

  cells_rd <- map(cells, ~ map(.x, mdxml_children_to_rd, state = state))
  rows_rd <- map_chr(cells_rd, paste0, collapse = " \\tab ")

  paste0("\\tabular{", paste(align, collapse = ""), "}{\n",
    paste("  ", rows_rd, "\\cr\n", collapse = ""),
  "}\n")
}

# A list, either bulleted or numbered
mdxml_list <- function(xml, state) {
  type <- xml_attr(xml, "type")
  if (type == "ordered") {
    paste0("\n\\enumerate{", mdxml_children_to_rd(xml, state), "\n}")
  } else {
    paste0("\n\\itemize{", mdxml_children_to_rd(xml, state), "\n}")
  }
}

mdxml_item <- function(xml, state) {
  ## A single item within a list. We remove the first paragraph
  ## tag, to avoid an empty line at the beginning of the first item.
  children <- xml_children(xml)
  if (length(children) == 0) {
    cnts <- ""
  } else if (xml_name(children[[1]]) == "paragraph") {
    cnts <- paste0(
      mdxml_children_to_rd(children[[1]], state),
      paste0(map_chr(children[-1], mdxml_node_to_rd, state), collapse = "")
    )
  } else {
    cnts <- mdxml_children_to_rd(xml, state)
  }
  paste0("\n\\item ", cnts)
}

mdxml_link <- function(xml, state) {
  ## Hyperlink, this can also be a link to a function
  dest <- xml_attr(xml, "destination")
  contents <- xml_contents(xml)

  link <- parse_link(dest, contents, state)

  if (!is.null(link)) {
    paste0(link, collapse = "")
  } else if (dest == "" || dest == xml_text(xml)) {
    paste0("\\url{", escape_comment(xml_text(xml)), "}")
  } else {
    paste0("\\href{", dest, "}{", mdxml_link_text(contents, state), "}")
  }
}

mdxml_link_text <- function(xml_contents, state) {
  # Newlines in markdown get converted to softbreaks/linebreaks by
  # markdown_xml(), which then get interpreted as empty strings by
  # xml_text(). So we preserve newlines as spaces.
  inlink <- state$inlink
  on.exit(state$inlink <- inlink, add = TRUE)
  state$inlink <- TRUE

  text <- map_chr(xml_contents, mdxml_node_to_rd, state)
  paste0(text, collapse = "")
}

mdxml_image = function(xml) {
  dest <- xml_attr(xml, "destination")
  title <- xml_attr(xml, "title")
  paste0("\\figure{", dest, "}{", title, "}")
}

escape_comment <- function(x) {
  gsub("%", "\\%", x, fixed = TRUE)
}

mdxml_heading <- function(xml, state) {
  level <- xml_attr(xml, "level")
  if (! state$has_sections && level == 1) {
    return(mdxml_unsupported(xml, state$tag, "level 1 markdown headings"))
  }
  txt <- map_chr(xml_contents(xml), mdxml_node_to_rd, state)
  head <- paste0(
    mdxml_close_sections(state, level),
    "\n",
    if (level == 1) paste0(state$section_tag, "\\section{"),
    if (level > 1) "\\subsection{",
    paste(txt, collapse = ""),
    "}{")
  state$section <- c(state$section, level)
  head
}

mdxml_html_block <- function(xml, state) {
  if (state$tag$tag != "includeRmd") {
    return(mdxml_unsupported(xml, state$tag, "HTML blocks"))
  }
  paste0(
    "\\if{html}{\\out{\n",
    gsub("}", "\\}", xml_text(xml), fixed = TRUE),
    "}}\n"
  )
}

mdxml_html_inline <- function(xml, state) {
  if (state$tag$tag != "includeRmd") {
    return(mdxml_unsupported(xml, state$tag, "inline HTML"))
  }
  paste0(
    "\\if{html}{\\out{",
    gsub("}", "\\}", xml_text(xml), fixed = TRUE),
    "}}"
  )
}

#' @importFrom utils head tail

mdxml_close_sections <- function(state, upto = 1L) {
  hmy <- 0L
  while (length(state$section) && tail(state$section, 1) >= upto) {
    hmy <- hmy + 1L
    state$section <- head(state$section, -1L)
  }

  paste0(rep("\n}\n", hmy), collapse = "")
}
