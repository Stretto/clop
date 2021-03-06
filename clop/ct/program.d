/*
 *  The MIT License (MIT)
 *  =====================
 *
 *  Copyright (c) 2015 Dmitri Makarov <dmakarov@alumni.stanford.edu>
 *
 *  Permission is hereby granted, free of charge, to any person obtaining a copy
 *  of this software and associated documentation files (the "Software"), to deal
 *  in the Software without restriction, including without limitation the rights
 *  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 *  copies of the Software, and to permit persons to whom the Software is
 *  furnished to do so, subject to the following conditions:
 *
 *  The above copyright notice and this permission notice shall be included in all
 *  copies or substantial portions of the Software.
 *
 *  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 *  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 *  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 *  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 *  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 *  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 *  SOFTWARE.
 */
module clop.ct.program;

import std.algorithm : reduce;
import std.container;
import std.conv;
import std.string;
import std.traits;
import std.typetuple;
debug (UNITTEST_DEBUG) import std.stdio;

import pegged.grammar;

import clop.ct.analysis;
import clop.ct.parser;
import clop.ct.structs;
import clop.ct.symbol;
import clop.ct.transform;
static import clop.ct.templates;

struct translation_result {
  string stmts;
  string value;
}

/**
 *  The container of all information related to a specific variant
 *  a CLOP program fragment.
 */
struct Program
{
  /**
   * Return the string that is this program's kernel source code.
   */
  string generate_code()
  {
    auto t = optimize(AST); // apply the optimizing transformations on the AST
    auto kbody = translate(t);  // generate OpenCL kernel source code from the AST
    auto kname = generate_kernel_name(); // we need to give the kernel a name
    generate_code_setting_kernel_parameters("instance_" ~ suffix ~ ".kernel");
    auto kernel = "macros ~ q{" ~ external ~ "} ~ \n"
                ~ "          \"__kernel void " ~ kname
                ~ "(\" ~ kernel_params ~ \")\" ~q{\n" ~ kbody ~ "          }";
    auto clhost = format(clop.ct.templates.template_create_opencl_kernel,
                         suffix, suffix, suffix, suffix, suffix,
                         suffix, kernel_parameter_list_code, suffix, kname , kernel);
    clhost ~= kernel_set_args_code
            ~ generate_code_to_invoke_kernel()
            ~ generate_code_to_pull_from_device()
            ~ generate_code_to_release_buffers();
    auto diagnostics = format("static if (\"%s\" != \"\")\n  pragma (msg, \"%s\");\n", errors, errors);
    return diagnostics ~ format(clop.ct.templates.template_clop_unit, clhost, toString());
  }

  @property
  string toString()
  {
    import std.algorithm : map, reduce;
    auto prefix = suffix;
    if (pattern !is null)
    {
      prefix ~= "_" ~ pattern;
    }
    return prefix ~ reduce!((a, b) => a ~ "_" ~ b)("", map!(a => a.toString)(trans));
  }

 private:

  Symbol[string] symtable; ///
  Transformation[] trans;  ///
  Argument[] parameters;   ///
  ParseTree AST;           ///
  Box range;               ///
  string[] lws;            ///
  string pattern;          ///
  string external;         ///
  string errors;           ///
  string suffix;           ///

  string indent = "            ";
  string block_size = "32"; ///
  bool use_shadow = false; ///
  string kernel_parameter_list_code;
  string kernel_set_args_code;
  uint temporary_id;
  string global_work_size;
  string local_work_size;
  string additional_arguments = "";
  string range_start = "0";
  string range_finish = "1";
  string kernel_object;
  string instance_object;
  ParseTree[] loops;
  ParseTree[] prefs;

  /**
   *
   */
  ParseTree optimize(ParseTree t)
  {
    instance_object = "instance_" ~ suffix;
    kernel_object = instance_object ~ ".kernel";
    auto r = t;
    foreach (f; trans)
      r = apply_trans(f, r);
    return r;
  }

  /**
   *
   */
  ParseTree apply_transformation(Transformation f, ParseTree t)
  {
    foreach (member; __traits (allMembers, Program))
    {
      if (pattern == member)
      {
        alias M = typeof (mixin ("this." ~ member));
        static if (isCallable!M &&
                   is (ReturnType!M == ParseTree) &&
                   is (ParameterTypeTuple!M == TypeTuple!(ParseTree)))
          return mixin ("this." ~ member ~ "(t)");
      }
    }
    errors ~= "CLOP: unknown syncronization pattern " ~ pattern ~ "\n";
    return t;
  }

  ParseTree apply_trans(Transformation f, ParseTree t)
  {
    debug (UNITTEST_DEBUG) writefln("Program.apply_trans(%s)", f.name);
    switch (f.name)
    {
    case "rectangular_tiling":
      if (pattern == "Antidiagonal")
        return apply_rectangular_tiling_with_antidiagonal_pattern(t);
      else if (pattern == "Horizontal")
        return apply_rectangular_tiling_with_horizontal_pattern(t);
      return t.dup;
    case "rhomboid_tiling":
      return apply_rhomboid_tiling_with_antidiagonal_pattern(t);
    case "prefetching":
      return apply_prefetching(t);
    default:
      errors ~= "CLOP error " ~ suffix ~ ": unknown transformation '" ~ f.name ~ "'\n";
      return t.dup;
    }
  }

  auto generate_shared_memory_variable(string v)
  {
    return v ~ "_in_shared_memory";
  }

  auto generate_kernel_name()
  {
    return format("clop_kernel_main_%s", toString());
  }

  /**
   * code generated for rectangular tiling depends on the
   * synchronization pattern.
   * There is nesting of transformations: the anti-diagonal pattern
   * should be applied to a block within a kernel invocation, and also
   * on the outside level to blocks.  Block is like a macro-element.
   */
  auto apply_rectangular_tiling(ParseTree t)
  {
    debug (UNITTEST_DEBUG) writefln("APPLY_RECTANGULAR_TILING started");
    if (t.name != "CLOP.CompoundStatement")
    {
      debug (UNITTEST_DEBUG) writefln("Node is not a CompoundStatement");
      return t;
    }
    auto s = CLOP.decimateTree(CLOP.Statement(format("for (int i = 0; i < %s; ++i) {}", block_size)));
    s.children[0].children[0].children[4].children[0] = t.children[0].children[$ - 1];
    t.children[0].children[$ - 1] = s;
    debug (UNITTEST_DEBUG) writefln("APPLY_RECTANGULAR_TILING is done");
    return t;
  }

  auto apply_rectangular_tiling_with_antidiagonal_pattern(ParseTree t)
  {
    if (t.name != "CLOP.CompoundStatement")
    {
      debug (UNITTEST_DEBUG) writefln("Node is not a CompoundStatement");
      return t;
    }
    auto interval_height= format("(%s) - (%s)", range.intervals[0].get_max(), range.intervals[0].get_min());
    auto interval_width = format("(%s) - (%s)", range.intervals[1].get_max(), range.intervals[1].get_min());
    range_finish = format("((%s) + (%s)) / (%s) - 1", interval_height, interval_width, block_size);
    local_work_size = format("(%s)", block_size);
    global_work_size= format("(%s) * (i + 1) < (%s) ? (%s) * (i + 1) : (%s) + (%s) - (%s) * (i + 1)",
                             block_size, interval_height, block_size, interval_height, interval_width, block_size);
    additional_arguments = format("clSetKernelArg(%s, %s, cl_int.sizeof, &i);", kernel_object, parameters[$ - 1].number);
    auto tx = CLOP.decimateTree(CLOP.Statement("tx = get_local_id(0);"));
    auto bx = CLOP.decimateTree(CLOP.Declaration(format("int bx = get_group_id(0);")));
    auto bs = CLOP.decimateTree(CLOP.Declaration(format("int bsz = get_local_size(0);")));
    auto nb = CLOP.decimateTree(CLOP.Declaration(format("int nbs = (%s) / bsz;", interval_height)));
    auto d0 = CLOP.decimateTree(CLOP.Declaration(format("int %s0 = (diagonal < nbs ? diagonal - bx : nbs - bx - %s) * bsz + %s;", range.symbols[0], range.intervals[1].get_min(), range.intervals[1].get_min())));
    auto d1 = CLOP.decimateTree(CLOP.Declaration(format("int %s0 = (diagonal < nbs ? bx : diagonal - nbs + bx + %s) * bsz + %s;", range.symbols[1], range.intervals[1].get_min(), range.intervals[1].get_min())));
    auto s = CLOP.decimateTree(CLOP.Statement(format(q{
            for (int i = 0; i < 2 * bsz - 1; ++i)
            {
              if ((i < bsz && tx <= i) || (i >= bsz && tx < 2 * bsz - 1 - i))
              {
                %s = i < bsz ? %s0 + i - tx : %s0     + bsz - 1 - tx;
                %s = i < bsz ? %s0     + tx : %s0 + i - bsz + 1 + tx;
              }
              barrier(CLK_LOCAL_MEM_FENCE);
            }}, range.symbols[0], range.symbols[0], range.symbols[0],
                  range.symbols[1], range.symbols[1], range.symbols[1])));
    auto loop_body = s.children[0].children[0].children[4];
    auto stmt_one = loop_body.children[0].children[0].children[0];
    auto then_part = stmt_one.children[0].children[1];
    then_part.children[0].children[0].children ~= t.children[0].children[$ - 1];
    t.children[0].children = t.children[0].children[0 .. $ - 1] ~ [tx, bx, bs, nb, d0, d1, s];
    return t;
  }

  auto apply_rhomboid_tiling_with_antidiagonal_pattern(ParseTree t)
  {
    debug (UNITTEST_DEBUG) writefln("APPLY_RHOMBOID_TILING");
    if (t.name != "CLOP.CompoundStatement")
    {
      debug (UNITTEST_DEBUG) writefln("Node is not a CompoundStatement");
      return t;
    }
    auto interval_height= format("(%s) - (%s)", range.intervals[0].get_max(), range.intervals[0].get_min());
    auto interval_width = format("(%s) - (%s)", range.intervals[1].get_max(), range.intervals[1].get_min());
    range_finish = format("(2 * (%s) + (%s)) / (%s) - 1", interval_height, interval_width, block_size);
    local_work_size = format("(%s)", block_size);
    global_work_size= format("(%s)", block_size);
    auto num_blocks = format(q{
        size_t max_blocks = (%s) / (2 * (%s)) + 1;
        size_t num_blocks = i / 2 + 1;
        if (num_blocks >= max_blocks)
        {
          auto start = max(0, (%s) + (i - 2 * (%s) / (%s) + 1) * (%s));
          num_blocks = start ? ((%s) - start + (%s)) / (2 * (%s))
                             : ((%s) + (2 - (i & 1)) * (%s)) / (2 * (%s));
        }
        global_work_size *= num_blocks;
      }, interval_width, block_size,
         range.intervals[0].get_min(), interval_width, block_size, block_size,
         range.intervals[0].get_max(), block_size, block_size,
         interval_width, block_size, block_size);
    additional_arguments = format("%sclSetKernelArg(%s, %s, cl_int.sizeof, &i);", num_blocks, kernel_object, parameters[$ - 1].number);
    auto tx = CLOP.decimateTree(CLOP.Statement(format("tx = get_local_id(0);")));
    auto bx = CLOP.decimateTree(CLOP.Declaration(format("int bx = get_group_id(0);")));
    auto bs = CLOP.decimateTree(CLOP.Declaration(format("int bsz = get_local_size(0);")));
    auto nb = CLOP.decimateTree(CLOP.Declaration(format("int nbs = 2 * (%s) / bsz;", interval_height)));
    auto d0 = CLOP.decimateTree(CLOP.Declaration(format("int %s0 = diagonal < nbs ? (%s) - 1 + bsz * (1 - bx + diagonal / 2) - tx : (%s) - bsz * bx - tx;", range.symbols[0], range.intervals[1].get_min(), interval_height)));
    auto d1 = CLOP.decimateTree(CLOP.Declaration(format("int %s0 = diagonal < nbs ? (%s) - ((diagonal + 1) & 1) * bsz + 2 * bx * bsz : (%s) + (diagonal + 1 - 2 * (%s) / bsz) * bsz + 2 * bx * bsz;", range.symbols[1], range.intervals[1].get_min(), range.intervals[1].get_min(), interval_width)));
    auto s = CLOP.decimateTree(CLOP.Statement(format(q{
            for (int i = 0; i < bsz; ++i)
            {
              %s = %s0;
              %s = %s0 + i;
              if (0 < %s && %s < (%s)) {}
              barrier(CLK_LOCAL_MEM_FENCE);
            }}, range.symbols[0], range.symbols[0], range.symbols[1], range.symbols[1], range.symbols[1], range.symbols[1], range.intervals[1].get_max())));
    auto loop_body = s.children[0].children[0].children[4];
    auto if_statem = loop_body.children[0].children[0].children[2];
    auto then_part = if_statem.children[0].children[1];
    then_part.children[0] = t.children[0].children[$ - 1];
    t.children[0].children = t.children[0].children[0 .. $ - 1] ~ [tx, bx, bs, nb, d0, d1, s];
    return t;
  }

  auto apply_rectangular_tiling_with_horizontal_pattern(ParseTree t)
  {
    if (t.name != "CLOP.CompoundStatement")
    {
      debug (UNITTEST_DEBUG) writefln("Node is not a CompoundStatement");
      return t;
    }
    auto height = "height";
    if (height !in symtable)
    {
      symtable[height] = Symbol(height, "int");
      parameters = parameters[0 .. $ - 1] ~ [Argument(height, `"int "`, "", "", "", true)] ~ [parameters[$ - 1]];
      parameters[$ - 2].number = to!(uint)(parameters.length) - 2;
    }
    auto interval_height= format("(%s) - (%s)", range.intervals[0].get_max(), range.intervals[0].get_min());
    auto interval_width = format("(%s) - (%s)", range.intervals[1].get_max(), range.intervals[1].get_min());
    range_finish = format("((%s) + (%s)) / (%s) - 1", interval_height, interval_width, block_size);
    local_work_size = format("(%s)", block_size);
    global_work_size= format("(%s) * (i + 1) < (%s) ? (%s) * (i + 1) : (%s) + (%s) - (%s) * (i + 1)",
                             block_size, interval_height, block_size, interval_height, interval_width, block_size);
    additional_arguments = format("clSetKernelArg(%s, %s, cl_int.sizeof, &height);", kernel_object, parameters[$ - 2].number);
    auto rs = CLOP.decimateTree(CLOP.Declaration(format("int start = %s;", range.symbols[0])));
    auto bx = CLOP.decimateTree(CLOP.Declaration(format("int bx = get_group_id(0);")));
    auto bs = CLOP.decimateTree(CLOP.Declaration(format("int bsz = get_local_size(0);")));
    auto tx = CLOP.decimateTree(CLOP.Statement(format("%s = bx * bsz - (height - 1) + get_local_id(0);", range.symbols[1])));
    auto s = CLOP.decimateTree(CLOP.Statement(format(q{
            for (int %s = %s; %s < %s; ++%s)
            {
              if (-1 < %s && %s < (%s)) {}
              barrier(CLK_GLOBAL_MEM_FENCE);
            }}, range.symbols[0], "start", range.symbols[0], "start + height", range.symbols[0],
                range.symbols[1], range.symbols[1], range.intervals[1].get_max())));
    auto loop_body = s.children[0].children[0].children[4];
    auto stmt_one = loop_body.children[0].children[0].children[0];
    auto then_part = stmt_one.children[0].children[1];
    then_part.children[0] = t.children[0].children[$ - 1];
    t.children[0].children = t.children[0].children[0 .. $ - 1] ~ [rs, bx, bs, tx, s];
    return t;
  }

  auto apply_prefetching(ParseTree t)
  {
    debug (UNITTEST_DEBUG) writefln("APPLY_PREFETCHING");
    // find loops, in loop body if an array is accessed load elements
    // from next iteration into local variable at the end of the
    // iteration and use the local variable in the current iteration.
    find_loops(t);
    foreach (n; loops)
    {
      add_prefetching_to_for_loop(n);
    }
    return t;
  }

  // if ( "CLOP.ArrayIndex" == t.children[1].name &&
  //      symtable.get( s, Symbol() ) != Symbol() &&
  //      symtable[s].shadow != null )
  // {
  //   use_shadow = true;
  //   s = symtable[s].shadow ~
  //       patch_index_expression_for_shared_memory( s, t.children[1] );
  //   use_shadow = false;
  // }
  // else
  auto patch_index_expression_for_shared_memory (string s, ParseTree t)
  {
    auto r = Box( [], [] );
    foreach ( c, v; range.symbols )
    {
      r.symbols ~= [v];
      r.s2i[v] = c;
      auto n = "0";
      auto x = "8"; // block_size;
      symtable[v].shadow = s ~ "_" ~ generate_shared_memory_variable( v );
      r.intervals ~= [
                      Interval(
                               ParseTree( "CLOP.IntegerLiteral", true, [n], "", 0, 0, [] ),
                               ParseTree( "CLOP.IntegerLiteral", true, [x], "", 0, 0, [] ) )
                      ];
    }
    auto uses = symtable[s].uses;
    Interval[3] local_box;
    foreach ( i, c; uses[0].children )
      local_box[i] = interval_apply( c, r );
    for ( auto ii = 1; ii < uses.length; ++ii )
      foreach ( i, c; uses[ii].children )
        local_box[i] = interval_union( local_box[i], interval_apply( c, r ) );
    auto u = t.children[0];
    auto bsz0 = local_box[0].get_size();
    auto bsz1 = local_box[1].get_size();
    auto x = "";
    switch ( u.children.length )
    {
      case 1:
        x = translate( u.children[0] );
        break;
      case 2:
        x = format( "(%s) * (%s) + (%s)", translate( u.children[1] ), bsz0,
                    translate( u.children[0] ) );
        break;
      case 3:
        x = format( "(%s) * (%s) * (%s) + (%s) * (%s) + (%s)",
                    translate( u.children[2] ), bsz1, bsz0,
                    translate( u.children[1] ), bsz1,
                    translate( u.children[0] ) );
        break;
      default:
        x = "0";
    }
    return format( "[%s]", x );
  }

  /**
   * Given a string that represents a name of a variable, return a
   * string that represents a parameter declaration that contains the
   * type of the parameter matching the variable's type and the
   * parameter name matching the variable's name.
   */
  void generate_code_setting_kernel_parameters(string kernel)
  {
    auto i = 0U;
    auto comma = "";
    kernel_parameter_list_code = q{
          auto kernel_params = "", macros = "";};
    kernel_set_args_code = "          // setting up buffers and kernel arguments";
    foreach(j, p; parameters)
    {
      if (!p.is_macro)
      {
        parameters[j].number = i;
        kernel_parameter_list_code ~= format(q{
          kernel_params ~= "%s%s" ~ %s ~ "%s";},
          comma, p.qual, p.type, p.name);
        if (p.to_push != "")
        {
          kernel_set_args_code ~= p.to_push;
        }
        if (!p.skip)
        {
          kernel_set_args_code ~= format(q{
          runtime.status = clSetKernelArg(%s, %s, %s, %s);
          assert(runtime.status == CL_SUCCESS, cl_strerror(runtime.status, "clSetKernelArg: %s"));
          }, kernel, i, p.size, p.address, i);
        }
        comma = ", ";
        ++i;
      }
      else
      {
        kernel_parameter_list_code ~= format(q{
          macros ~= "#define %s " ~ format("%%s\n", %s);},
          p.name, p.name);
      }
    }
  }

  string generate_code_to_pull_from_device()
  {
    auto result = "";
    foreach (p; parameters)
    {
      auto v = symtable[p.name];
      if (p.to_pull != "" && v.defs.length > 0)
      {
        result ~= p.to_pull;
      }
    }
    return result;
  }

  string generate_code_to_release_buffers()
  {
    auto result = "";
    foreach (p; parameters)
    {
      if (p.to_release != "")
      {
        result ~= p.to_release;
      }
    }
    return result;
  }

  /**
   * Generate the host code that invokes the OpenCL kernel with proper
   * synchronization pattern.  The code defines the parameters of
   * the kernel's NDRange and then uses the clEnqueueNDRangeKernel
   * call to launch the kernel.
   */
  string generate_code_to_invoke_kernel()
  {

    if (pattern is null)
    {
      auto wgsize = lws is null ? "null" : "[" ~ reduce!`a ~ "," ~ b`(lws[0], lws[1 .. $]) ~ "]";
      auto global = "[" ~ range.get_interval_sizes() ~ "]";
      auto offset = "[" ~ range.get_lower_bounds() ~ "]";
      auto dimensions = range.get_dimensions();
      return format(clop.ct.templates.template_plain_invoke_kernel, offset, global, wgsize, kernel_object, dimensions);
    }
    if (pattern == "Antidiagonal")
    {
      if (global_work_size == "")
      {
        auto interval_height= format("(%s) - (%s)", range.intervals[0].get_max(), range.intervals[0].get_min());
        auto interval_width = format("(%s) - (%s)", range.intervals[1].get_max(), range.intervals[1].get_min());
        global_work_size = format("i < (%s) ? i + 1 : (%s) + (%s) - i - 1", interval_height, interval_height, interval_width);
        local_work_size = format("%s.get_work_group_size(global_work_size)", instance_object);
        range_finish = format("(%s) + (%s) - 1", interval_height, interval_width);
        additional_arguments = format("clSetKernelArg(%s, %s, cl_int.sizeof, &i);", kernel_object, parameters[$ - 1].number);
      }
      return format(clop.ct.templates.template_kernel_invocation_loop,
                    range_start,
                    range_finish,
                    global_work_size,
                    local_work_size,
                    additional_arguments,
                    kernel_object);
    }
    if (pattern == "Horizontal")
    {
      global_work_size = format("(%s) - (%s)", range.intervals[1].get_max(), range.intervals[1].get_min());
      range_start = format("(%s)", range.intervals[0].get_min());
      range_finish = format("(%s)", range.intervals[0].get_max());
      additional_arguments ~= format("clSetKernelArg(%s, %s, cl_int.sizeof, &i);", kernel_object, parameters[$ - 1].number);
      bool use_loop_with_step = false;
      foreach (t; trans)
      {
        if (t.name == "rectangular_tiling")
          use_loop_with_step = true;
      }
      if (use_loop_with_step)
      {
        local_work_size = format("%s.get_work_group_size(BLOCK_SIZE)", instance_object);
        return format(clop.ct.templates.template_kernel_invocation_loop_with_step,
                      range_start,
                      range_finish,
                      "height",
                      global_work_size,
                      local_work_size,
                      additional_arguments,
                      kernel_object);
      }
      else
      {
        local_work_size = format("%s.get_work_group_size(global_work_size)", instance_object);
        return format(clop.ct.templates.template_kernel_invocation_loop,
                      range_start,
                      range_finish,
                      global_work_size,
                      local_work_size,
                      additional_arguments,
                      kernel_object);
      }
    }
    return "";
  }

  /**
   *  For multidimensional arrays linearize the index expressions.
   */
  translation_result translate_index_expression(string v, ParseTree t)
  {
    string value = "", stmts = "";
    if (t.children.length == 1 || t.children.length != range.get_dimensions() || v !in symtable || symtable[v].box is null)
    {
      debug (UNITTEST_DEBUG)
      {
        writefln("Can't linearize index expression %s %s not in st %s, box is null %s",
                 v, t.matches, v !in symtable, symtable[v].box is null);
      }
      return translate_expression(t);
    }
    auto r = translate_expression(t.children[0]);
    value = r.value;
    stmts = r.stmts;
    foreach (i, c; t.children[1 .. $])
    {
      auto q = translate_expression(c);
      stmts ~= q.stmts;
      value = "(" ~ value ~ ") * (" ~ symtable[v].box[i + 1].get_size() ~ ") + " ~ q.value;
    }
    return translation_result(stmts, value);
  }

  /**
   *
   */
  Symbol create_new_temporary(string lhs)
  {
    auto n = format("clop_tmp_%s", temporary_id++);
    // FIXME: get the type from lhs.
    auto t = "float";
    auto s = Symbol(n, t);
    symtable[n] = s;
    return s;
  }

  /**
   *
   */
  translation_result translate_expression(ParseTree t)
  {
    string stmts = "", value = "";
    switch (t.name)
    {
    case "CLOP.InitDeclaratorList":
      {
        foreach (i, c; t.children)
        {
          auto r = translate_expression(c);
          stmts ~= r.stmts;
          value ~= (i == 0) ? r.value : ", " ~ r.value;
        }
        break;
      }
    case "CLOP.InitDeclarator":
      {
        value = translate(t.children[0]);
        if (t.children.length > 1)
        {
          auto r = translate_expression(t.children[1]);
          value ~= " = " ~ r.value;
          stmts = r.stmts;
        }
        break;
      }
    case "CLOP.Initializer":
      {
        auto r = translate_expression(t.children[0]);
        value = r.value;
        stmts = r.stmts;
        break;
      }
    case "CLOP.PrimaryExpr":
      {
        auto r = translate_expression(t.children[0]);
        value = "(" == t.matches[0] ? "(" ~ r.value ~ ")" : r.value;
        stmts = r.stmts;
        break;
      }
    case "CLOP.PostfixExpr":
      {
        auto is_snippet = t.children[0].children.length == 2;
        if (is_snippet)
        {
          switch (t.children[0].children[0].matches[0])
          {
          case "reduce":
            {
              // FIXME: replace the hardcoded values with code that
              // generates the necessary information.
              auto array_name = t.children[1].children[1].matches[0];
              auto array_symbol = symtable[array_name];
              auto func_name = "clop_binary_function";
              auto type = array_symbol.type[0 .. $ - 1];
              auto length = array_symbol.length;
              value = "reduce_result";
              stmts = "              " ~ type ~ " " ~ value ~ ";";
              stmts ~= clop.ct.templates.reduce.instantiate_template(func_name, t.children[1], value, length);
              debug (UNITTEST_DEBUG) writefln("UT:%s template expanded to %s", suffix, stmts);
            }
            break;
          default: {/+ do nothing +/}
          }
        }
        else if (t.children.length == 2)
        {
          auto r = translate_expression(t.children[0]);
          value = r.value;
          stmts = r.stmts;
          if (t.children[1].name == "CLOP.Expression")
          {
            if (t.children[0].name == "CLOP.PrimaryExpr" &&
                t.children[0].children[0].name == "CLOP.Identifier")
            {
              auto q = translate_index_expression(t.children[0].children[0].matches[0], t.children[1]);
              value ~= "[" ~ q.value ~ "]";
              stmts ~= q.stmts;
            }
            else
            {
              r = translate_expression(t.children[1]);
              value ~= "[" ~ r.value ~ "]";
              stmts = r.stmts;
            }
          }
          else if (t.children[1].name == "CLOP.ArgumentExprList")
          {
            r = translate_expression(t.children[1]);
            value ~= "(" ~ r.value ~ ")";
            stmts = r.stmts;
          }
          else
          {
            r = translate_expression(t.children[1]);
            value ~= "." ~ r.value;
            stmts = r.stmts;
          }
        }
        else
        {
          auto r = translate_expression(t.children[0]);
          value = r.value;
          stmts = r.stmts;
          if (t.matches.length > 2 && "(" == t.matches[$ - 2] && ")" == t.matches[$ - 1])
          {
            value ~= "()";
          }
          else if ("++" == t.matches[$ - 1])
          {
            value ~= "++";
          }
          else if ("--" == t.matches[$ - 1])
          {
            value ~= "--";
          }
        }
        break;
      }
    case "CLOP.ArgumentExprList":
      {
        foreach (i, c; t.children)
        {
          auto r = translate_expression(c);
          value ~= i == 0 ? r.value : ", " ~ r.value;
          stmts ~= r.stmts;
        }
        break;
      }
    case "CLOP.UnaryExpr":
      {
        if (t.children.length == 1)
        {
          auto r = translate_expression(t.children[0]);
          value = r.value;
          stmts = r.stmts;
        }
        else
        {
          auto r = translate_expression(t.children[1]);
          value = t.children[0].matches[0] ~ r.value;
          stmts = r.stmts;
        }
        break;
      }
    case "CLOP.IncrementExpr":
      {
        auto r = translate_expression(t.children[0]);
        value = "++" ~ r.value;
        stmts = r.stmts;
        break;
      }
    case "CLOP.DecrementExpr":
      {
        auto r = translate_expression(t.children[0]);
        value = "--" ~ r.value;
        stmts = r.stmts;
        break;
      }
    case "CLOP.CastExpr":
      {
        if (t.children.length == 1)
        {
          auto r = translate_expression(t.children[0]);
          value = r.value;
          stmts = r.stmts;
        }
        else
        {
          auto r = translate_expression(t.children[1]);
          value = "(" ~ translate(t.children[0]) ~ ")" ~ r.value;
          stmts = r.stmts;
        }
        break;
      }
    case "CLOP.MultiplicativeExpr", "CLOP.AdditiveExpr", "CLOP.ShiftExpr":
    case "CLOP.RelationalExpr", "CLOP.EqualityExpr":
      {
        auto r = translate_expression(t.children[0]);
        value = r.value;
        stmts = r.stmts;
        for (auto i = 1; i < t.children.length; i += 2)
        {
          r = translate_expression(t.children[i + 1]);
          value ~= " " ~ t.children[i].matches[0] ~ " " ~ r.value;
          stmts ~= r.stmts;
        }
        break;
      }
    case "CLOP.ANDExpr":
      {
        auto r = translate_expression(t.children[0]);
        value = r.value;
        stmts = r.stmts;
        foreach (i; 1 .. t.children.length)
        {
          r = translate_expression(t.children[i]);
          value ~= " & " ~ r.value;
          stmts ~= r.stmts;
        }
        break;
      }
    case "CLOP.ExclusiveORExpr":
      {
        auto r = translate_expression(t.children[0]);
        value = r.value;
        stmts = r.stmts;
        foreach (i; 1 .. t.children.length)
        {
          r = translate_expression(t.children[i]);
          value ~= " ^ " ~ r.value;
          stmts ~= r.stmts;
        }
        break;
      }
    case "CLOP.InclusiveORExpr":
      {
        auto r = translate_expression(t.children[0]);
        value = r.value;
        stmts = r.stmts;
        foreach (i; 1 .. t.children.length)
        {
          r = translate_expression(t.children[i]);
          value ~= " | " ~ r.value;
          stmts ~= r.stmts;
        }
        break;
      }
    case "CLOP.LogicalANDExpr":
      {
        auto r = translate_expression(t.children[0]);
        value = r.value;
        stmts = r.stmts;
        foreach (i; 1 .. t.children.length)
        {
          r = translate_expression(t.children[i]);
          value ~= " && " ~ r.value;
          stmts ~= r.stmts;
        }
        break;
      }
    case "CLOP.LogicalORExpr":
      {
        auto r = translate_expression(t.children[0]);
        value = r.value;
        stmts = r.stmts;
        foreach (i; 1 .. t.children.length)
        {
          r = translate_expression(t.children[i]);
          value ~= " || " ~ r.value;
          stmts ~= r.stmts;
        }
        break;
      }
    case "CLOP.ConditionalExpr":
      {
        auto r = translate_expression(t.children[0]);
        value = r.value;
        stmts = r.stmts;
        if (t.children.length == 3)
        {
          auto then_part = translate_expression(t.children[1]);
          auto else_part = translate_expression(t.children[2]);
          value ~= " ? " ~ then_part.value ~ " : " ~ else_part.value;
          stmts ~= then_part.stmts ~ else_part.stmts;
        }
        break;
      }
    case "CLOP.AssignmentExpr":
      {
        if (t.children.length == 3)
        {
          auto lhs = translate_expression(t.children[0]);
          stmts = lhs.stmts;
          auto rhs = translate_expression(t.children[2]);
          stmts ~= rhs.stmts;
          value = lhs.value ~ " " ~ t.children[1].matches[0] ~ " " ~ rhs.value;
        }
        else
        {
          auto r = translate_expression(t.children[0]);
          value = r.value;
          stmts = r.stmts;
        }
        break;
      }
    case "CLOP.Expression":
      {
        foreach (i, c; t.children)
        {
          auto r = translate_expression(c);
          value ~= i == 0 ? r.value : ", " ~ r.value;
          stmts ~= r.stmts;
        }
        break;
      }
    case "CLOP.Identifier":
      {
        value = t.matches[0];
        if (use_shadow && value in symtable && symtable[value].shadow != null)
          value = symtable[value].shadow;
        break;
      }
    case "CLOP.IntegerLiteral":
    case "CLOP.FloatLiteral":
      {
        value = t.matches[0];
        break;
      }
    default:
      break;
    }
    return translation_result(stmts, value);
  }

  /**
   *
   */
  void find_loops(ParseTree t)
  {
    switch (t.name)
    {
    case "CLOP.Statement":
      {
        find_loops(t.children[0]);
      }
      break;
    case "CLOP.CompoundStatement":
      {
        if (t.children.length > 0)
          find_loops(t.children[0]);
      }
      break;
    case "CLOP.StatementList":
      {
        foreach (c; t.children)
          find_loops(c);
      }
      break;
    case "CLOP.IfStatement":
      {
        find_loops(t.children[1]);
        if (t.children.length > 2)
          find_loops(t.children[2]);
      }
      break;
    case "CLOP.IterationStatement":
      {
        find_loops(t.children[0]);
      }
      break;
    case "CLOP.ForStatement":
      {
        loops ~= t;
      }
      break;
    default:
      {
      }
    }
  }

  /**
   *
   */
  void add_prefetching_to_for_loop(ParseTree t)
  {
    debug (UNITTEST_DEBUG)
    {
      writeln("Adding prefetching in a loop...");
    }
    auto index_variable = get_loop_index_variable(t);
    find_global_access_statements(get_loop_body(t));
  }

  string get_loop_index_variable(ParseTree t)
  {
    // FIXME: for now not implemented, just return "i";
    return "i";
  }

  ParseTree get_loop_body(ParseTree t)
  {
    // FIXME: return the last child, works for for-loops.
    return t.children[$ - 1];
  }

  void find_global_access_statements(ParseTree t)
  {
    switch (t.name)
    {
    case "CLOP.Declaration":
      {
        break;
      }
    case "CLOP.Declarator":
      {
        break;
      }
    case "CLOP.DeclarationSpecifiers":
      {
        break;
      }
    case "CLOP.StorageClassSpecifier":
      {
        break;
      }
    case "CLOP.TypeSpecifier":
      {
        break;
      }
    case "CLOP.ParameterList":
      {
        break;
      }
    case "CLOP.ParameterDeclaration":
      {
        break;
      }
    case "CLOP.StatementList":
      {
        foreach (c; t.children)
          find_global_access_statements(c);
        break;
      }
    case "CLOP.Statement":
      {
        find_global_access_statements(t.children[0]);
        break;
      }
    case "CLOP.CompoundStatement":
      {
        if (t.children.length > 0)
          find_global_access_statements(t.children[0]);
        break;
      }
    case "CLOP.ExpressionStatement":
      {
        if (has_prefetching_candidates(t.children[0]))
          prefs ~= t;
        break;
      }
    case "CLOP.IfStatement":
      {
        break;
      }
    case "CLOP.IterationStatement":
      {
        break;
      }
    case "CLOP.ForStatement":
      {
        break;
      }
    case "CLOP.ReturnStatement":
      {
        break;
      }
    case "CLOP.Identifier":
      {
        break;
      }
    case "CLOP.IntegerLiteral":
      {
        break;
      }
    case "CLOP.FloatLiteral":
      {
        break;
      }
    default:
      {
        break;
      }
    }
  }

  bool has_prefetching_candidates(ParseTree t)
  {
    switch (t.name)
    {
    case "CLOP.Expression":
      {
        foreach (c; t.children)
          if (has_prefetching_candidates(c))
            return true;
        return false;
      }
    default:
      return false;
    }
  }

  /**
   *
   */
  string translate(ParseTree t)
  {
    switch (t.name)
    {
    case "CLOP.Declaration":
      {
        auto s = indent ~ translate(t.children[0]);
        if (t.children.length > 1)
        {
          auto r = translate_expression(t.children[1]);
          s = r.stmts ~ s ~ " " ~ r.value;
        }
        return s ~ ";\n";
      }
    case "CLOP.Declarator":
      {
        string s = translate(t.children[0]);
        string b = t.matches[$ - 1] == "]" ? "[" : "(";
        if (t.children.length > 1)
        {
          if (t.children[1].name == "CLOP.ConditionalExpr")
          {
            auto r = translate_expression(t.children[1]);
            s = r.stmts ~ s ~ b ~ r.value ~ t.matches[$ - 1];
          }
          else
          {
            s ~= b ~ translate(t.children[1]) ~ t.matches[$ - 1];
          }
        }
        return s;
      }
    case "CLOP.DeclarationSpecifiers":
      {
        string s = translate(t.children[0]);
        if (t.children.length > 1)
          s ~= " " ~ translate(t.children[1]);
        return s;
      }
    case "CLOP.StorageClassSpecifier":
      {
        return "//";
      }
    case "CLOP.TypeSpecifier":
      {
        return t.matches[0];
      }
    case "CLOP.ParameterList":
      {
        return reduce!((a, b) => a ~ ", " ~ translate(b))(translate(t.children[0]), t.children[1 .. $]);
      }
    case "CLOP.ParameterDeclaration":
      {
        return translate(t.children[0]) ~ " " ~ translate(t.children[1]);
      }
    case "CLOP.StatementList":
      {
        return reduce!((a, b) => a ~ translate(b))("", t.children);
      }
    case "CLOP.Statement":
      {
        debug (UNITTEST_DEBUG) writefln("UT:%s Program.translate case CLOP.Statement: %s", suffix, t.matches);
        return translate(t.children[0]);
      }
    case "CLOP.CompoundStatement":
      {
        debug (UNITTEST_DEBUG)
        {
          writefln("UT:%s Program.translate case CLOP.CompoundStatement: %s", suffix, t.matches);
        }
        indent ~= "  ";
        auto s = translate(t.children[0]);
        indent = indent[0 .. $ - 2];
        return t.children.length == 1 ? indent ~ "{\n" ~ s ~ indent ~ "}\n" : "{}\n";
      }
    case "CLOP.ExpressionStatement":
      {
        debug (UNITTEST_DEBUG) writefln("UT:%s Program.translate case CLOP.ExpressionStatement: %s", suffix, t.matches);
        auto r = translate_expression(t.children[0]);
        return r.stmts ~ indent ~ r.value ~ ";\n";
      }
    case "CLOP.IfStatement":
      {
        auto r = translate_expression(t.children[0]);
        indent ~= "  ";
        auto then_part = translate(t.children[1]);
        auto else_part = "";
        if (t.children.length == 3)
          else_part = translate(t.children[2]);
        indent = indent[0 .. $ - 2];
        auto s = format("%s%sif (%s)\n%s", r.stmts, indent, r.value, then_part);
        if (else_part != "")
          s ~= indent ~ "else\n" ~ else_part;
        return s;
      }
    case "CLOP.IterationStatement":
      {
        return translate(t.children[0]);
      }
    case "CLOP.ForStatement":
      {
        auto s = "";
        indent ~= "  ";
        auto index = t.children.length == 5 ? 1 : 0;
        auto init_part = translate(t.children[index++]);
        if (index == 2) init_part = t.children[0].matches[0] ~ " " ~ init_part;
        auto cond_part = translate(t.children[index++]);
        auto step_part = translate_expression(t.children[index++]);
        auto loop_body = translate(t.children[index]);
        indent = indent[0 .. $ - 2];
        s ~= step_part.stmts;
        s ~= indent ~ "for (" ~ init_part ~ cond_part ~ step_part.value ~ ")\n" ~ indent ~ loop_body;
        return s;
      }
    case "CLOP.ReturnStatement":
      {
        return indent ~ (t.children.length == 1 ? "return " ~ translate(t.children[0]) ~ ";\n" : "return;\n");
      }
    case "CLOP.Identifier":
      {
        auto s = t.matches[0];
        if (use_shadow && s in symtable && symtable[s].shadow != null)
          s = symtable[s].shadow;
        return s;
      }
    case "CLOP.IntegerLiteral":
    case "CLOP.FloatLiteral":
      {
        return t.matches[0];
      }
    default: return t.name;
    }
  }

} // Program struct

unittest
{
  static import clop.ct.parser;
  static import clop.ct.stage2;
  static import clop.rt.ndarray;

  alias Fa = clop.rt.ndarray.NDArray!float;
  alias Ia = clop.rt.ndarray.NDArray!int;

  // test 1
  version (disabled)
  {
    auto t1 = clop.ct.parser.CLOP(q{
        NDRange(i : 1 .. h_n, j : 0 .. i_n)
        {
          local float t[i_n];
          t[j] = inputs[j] * weights[i, j];
          float s = reduce!"a + b"(0, t);
          if (j == 0)
          {
            hidden[i] = ONEF / (ONEF + exp(-s));
          }
        }});
    alias T1 = std.typetuple.TypeTuple!(size_t, float*, size_t, Fa, Fa, Fa);
    auto be1 = clop.ct.stage2.Backend!T1(t1, __FILE__, __LINE__, ["h_n", "t", "i_n", "inputs", "weights", "hidden"]);
    be1.analyze(t1);
    be1.update_parameters();
    be1.lower(t1);
    be1.compute_intervals();
    auto p1 = Program(be1.symtable, [], be1.parameters, be1.KBT, be1.range, be1.lws, be1.pattern, "", "", be1.suffix);
    auto k1 = p1.translate(be1.KBT);
    debug (UNITTEST_DEBUG) writefln("UT:%s k:\n%s", be1.suffix, k1);
    auto c1 = p1.generate_code();
    debug (UNITTEST_DEBUG) writefln("UT:%s c:\n%s", be1.suffix, c1);
  }

  // test 2
  version (disabled)
  {
    auto t2 = clop.ct.parser.CLOP(q{
        NDRange(tid : 0 .. gws $ wgs)
        {
          int group_index = get_group_id(0) + 1;
          int local_index = get_local_id(0);
          local float scratch[wgs];
          float s = 0.0;
          int j;
          for (j = 1; tid + j < input_n + 1; j += gws)
          {
            s += input_units[j] * i2h_weights[group_index * (input_n + 1) + j];
          }
          scratch[local_index] = s;
          s = reduce!"a + b"(0, scratch);
          if (local_index == 0)
          {
            hidden_units[group_index] = s;
          }
        }});
    alias T2 = std.typetuple.TypeTuple!(size_t, size_t, size_t, float*, Fa, Fa, Fa);
    auto be2 = clop.ct.stage2.Backend!T2(t2, __FILE__, __LINE__, ["gws", "wgs", "input_n", "scratch", "input_units", "i2h_weights", "hidden_units"]);
    be2.analyze(t2);
    be2.update_parameters();
    be2.lower(t2);
    be2.compute_intervals();
    auto p2 = Program(be2.symtable, [], be2.parameters, be2.KBT, be2.range, be2.lws, be2.pattern, "", "", be2.suffix);
    auto k2 = p2.translate(be2.KBT);
    debug (UNITTEST_DEBUG) writefln("UT:%s k:\n%s", be2.suffix, k2);
    auto c2 = p2.generate_code();
    debug (UNITTEST_DEBUG) writefln("UT:%s c:\n%s", be2.suffix, c2);
  }

  // test 3
  version (disabled)
  {
    auto t3 = clop.ct.parser.CLOP(q{
        int max3(int a, int b, int c) {
          int k = a > b ? a : b;
          return k > c ? k : c;
        }
        Antidiagonal NDRange(r : 1 .. rows, c : 1 .. cols) {
          F[r, c] = max3(F[r - 1, c - 1] + BLOSUM62[M[r] * CHARS + N[c]], F[r, c - 1] - penalty, F[r - 1, c] - penalty);
        } apply(rectangular_tiling(BLOCK_SIZE, BLOCK_SIZE))
      });
    alias T3 = std.typetuple.TypeTuple!(size_t, size_t, Ia, Ia, Ia, Ia, int);
    auto be3 = clop.ct.stage2.Backend!T3(t3, __FILE__, __LINE__, ["rows", "cols", "F", "BLOSUM62", "M", "N", "penalty"]);
    be3.analyze(t3);
    be3.update_parameters();
    be3.compute_intervals();
    auto o3 = [Transformation("rectangular_tiling", ["BLOCK_SIZE", "BLOCK_SIZE"]), Transformation("prefetching", [])];
    auto p3 = Program(be3.symtable, o3, be3.parameters, be3.KBT, be3.range, be3.lws, be3.pattern, "", "", be3.suffix);
    auto k3 = p3.translate(p3.optimize(be3.KBT));
    debug (UNITTEST_DEBUG) writefln("UT:%s k:\n%s", be3.suffix, k3);
    auto i3 = p3.generate_code_to_invoke_kernel();
    debug (UNITTEST_DEBUG) writefln("UT:%s code to invoke kernel:\n%s", be3.suffix, i3);
  }

  // test pathfinder
  {
    auto source_code_pathfinder = clop.ct.parser.CLOP(q{
      int min3(int a, int b, int c)
      {
        return a < b ? (c < a ? c : a) : (c < b ? c : b);
      }
      int mov3(int w, int s, int e)
      {
        return w < s ? (e < w ? -1 : 1) : (e < s ? -1 : 0);
      }
      Horizontal NDRange(r : 1 .. rows, c : 0 .. cols) {
        int s = dsums[r - 1, c];
        int w = (c > 0       ) ? dsums[r - 1, c - 1] : INT_MAX;
        int e = (c < cols - 1) ? dsums[r - 1, c + 1] : INT_MAX;
        dsums[r, c] = data[r, c] + min3(w, s, e);
        move[r, c] = mov3(w, s, e);
      }
    });
    alias kernel_param_types_pathfinder = std.typetuple.TypeTuple!(size_t, size_t, Ia, Ia);
    auto backend_pathfinder = clop.ct.stage2.Backend!kernel_param_types_pathfinder(source_code_pathfinder, __FILE__, __LINE__, ["rows", "cols", "dsums", "data"]);
    backend_pathfinder.analyze(source_code_pathfinder);
    backend_pathfinder.update_parameters();
    backend_pathfinder.compute_intervals();
    auto program_pathfinder = Program(backend_pathfinder.symtable,
                                      [],
                                      backend_pathfinder.parameters,
                                      backend_pathfinder.KBT,
                                      backend_pathfinder.range,
                                      backend_pathfinder.lws,
                                      backend_pathfinder.pattern,
                                      "",
                                      "",
                                      backend_pathfinder.suffix);
    auto kernel_pathfinder = program_pathfinder.translate(program_pathfinder.optimize(backend_pathfinder.KBT));
    debug (UNITTEST_DEBUG) writefln("UT:%s k:\n%s", backend_pathfinder.suffix, kernel_pathfinder);
    auto host_side_pathfinder = program_pathfinder.generate_code_to_invoke_kernel();
    debug (UNITTEST_DEBUG) writefln("UT:%s code to invoke kernel:\n%s", backend_pathfinder.suffix, host_side_pathfinder);
  }
}

// Local Variables:
// compile-command: "../../tests/test_module clop.ct.program"
// End:
