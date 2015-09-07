#define F(i, j)  input_itemsets_l[ (j)      +  (i)      * (BLOCK + 1)]
#define N(i, j)  input_itemsets_l[((j) - 1) +  (i)      * (BLOCK + 1)]
#define W(i, j)  input_itemsets_l[ (j)      + ((i) - 1) * (BLOCK + 1)]
#define NW(i, j) input_itemsets_l[((j) - 1) + ((i) - 1) * (BLOCK + 1)]
#define S(i, j)  similarity_l[(j) + (i) * BLOCK]
#define I(r,c) ((r) * cols + (c))

int
max3( int a, int b, int c )
{
  int k = a > b ? a : b;
  return k > c ? k : c;
}

__kernel void
nw1( __global int *similarity_d,
     __global int *input_itemsets_d,
     int cols, int penalty, int blk,
     int block_width, int worksize,
     int offset_r, int offset_c,
     __local int *input_itemsets_l,
     __local int *similarity_l )
{
  // Block index
  int bx = get_group_id(0);
  // Thread index
  int tx = get_local_id(0);
  // Base elements
  int base = offset_r * cols + offset_c;
  int b_index_x = bx;
  int b_index_y = blk - 1 - bx;
  int index_nw  = base + cols * BLOCK * b_index_y + BLOCK * b_index_x;
  int index_w   = index_nw + cols;
  int index_n   = index_nw + tx + 1;
  int index     = index_n  + cols;
  if (tx == 0) F(tx, 0) = input_itemsets_d[index_nw];
  barrier( CLK_LOCAL_MEM_FENCE );
  for ( int ty = 0; ty < BLOCK; ++ty )
    S(ty, tx) =  similarity_d[index + cols * ty];
  barrier( CLK_LOCAL_MEM_FENCE );
  F((tx + 1), 0) = input_itemsets_d[index_w + cols * tx];
  barrier( CLK_LOCAL_MEM_FENCE );
  F(0, (tx + 1)) = input_itemsets_d[index_n];
  barrier( CLK_LOCAL_MEM_FENCE );
  for ( int m = 0; m < BLOCK; ++m )
  {
    if ( tx <= m )
    {
      int t_index_x =  tx + 1;
      int t_index_y =  m - tx + 1;
      int match = NW( t_index_y, t_index_x ) + S( t_index_y - 1, t_index_x - 1 );
      int remove = W( t_index_y, t_index_x ) - penalty;
      int insert = N( t_index_y, t_index_x ) - penalty;
      F(t_index_y, t_index_x) = max3( match, remove, insert );
    }
    barrier( CLK_LOCAL_MEM_FENCE );
  }
  barrier( CLK_LOCAL_MEM_FENCE );
  for ( int m = BLOCK - 2; m >=0; --m )
  {
    if ( tx <= m )
    {
      int t_index_x =  tx + BLOCK - m ;
      int t_index_y =  BLOCK - tx;
      int match = NW( t_index_y, t_index_x ) + S( t_index_y - 1, t_index_x - 1 );
      int remove = W( t_index_y, t_index_x ) - penalty;
      int insert = N( t_index_y, t_index_x ) - penalty;
      F(t_index_y, t_index_x) = max3( match, remove, insert );
    }
    barrier( CLK_LOCAL_MEM_FENCE );
  }
  for ( int ty = 0 ; ty < BLOCK ; ++ty )
    input_itemsets_d[index + ty * cols] = F( ty + 1, tx + 1 );
}

__kernel void
nw2( __global int *similarity_d,
     __global int *input_itemsets_d,
     int cols, int penalty, int blk,
     int block_width, int worksize,
     int offset_r, int offset_c,
     __local int *input_itemsets_l,
     __local int *similarity_l )
{
  int bx = get_group_id(0);
  // Thread index
  int tx = get_local_id(0);
  // Base elements
  int base = offset_r * cols + offset_c;
  int b_index_x = bx + block_width - blk;
  int b_index_y = block_width - bx - 1;
  int index_nw  = base + cols * BLOCK * b_index_y + BLOCK * b_index_x;
  int index_w   = index_nw + cols;
  int index_n   = index_nw + tx + 1;
  int index     = index_n + cols;
  if (tx == 0) F(tx, 0) = input_itemsets_d[index_nw];
  for ( int ty = 0; ty < BLOCK; ++ty )
    S(ty, tx) =  similarity_d[index + cols * ty];
  barrier( CLK_LOCAL_MEM_FENCE );
  F((tx + 1), 0) = input_itemsets_d[index_w + cols * tx];
  barrier( CLK_LOCAL_MEM_FENCE );
  F(0, (tx + 1)) = input_itemsets_d[index_n];
  barrier( CLK_LOCAL_MEM_FENCE );
  for ( int m = 0 ; m < BLOCK ; ++m )
  {
    if ( tx <= m )
    {
      int t_index_x =  tx + 1;
      int t_index_y =  m - tx + 1;
      int match = NW( t_index_y, t_index_x ) + S( t_index_y - 1, t_index_x - 1 );
      int remove = W( t_index_y, t_index_x ) - penalty;
      int insert = N( t_index_y, t_index_x ) - penalty;
      F(t_index_y, t_index_x) = max3( match, remove, insert );
    }
    barrier( CLK_LOCAL_MEM_FENCE );
  }
  for ( int m = BLOCK - 2; m >= 0; --m )
  {
    if ( tx <= m )
    {
      int t_index_x =  tx + BLOCK - m ;
      int t_index_y =  BLOCK - tx;
      int match = NW( t_index_y, t_index_x ) + S( t_index_y - 1, t_index_x - 1 );
      int remove = W( t_index_y, t_index_x ) - penalty;
      int insert = N( t_index_y, t_index_x ) - penalty;
      F(t_index_y, t_index_x) = max3( match, remove, insert );
    }
    barrier( CLK_LOCAL_MEM_FENCE );
  }
  for ( int ty = 0 ; ty < BLOCK ; ++ty )
    input_itemsets_d[index + ty * cols] = F( ty + 1, tx + 1 );
}

__kernel void rhombus(__global const int* A,
                      __global const int* P,
                      __global const int* Q,
                      __global       int* B,
                                     int  cols,
                                     int  penalty,
                                     int  br,
                                     int  bc)
{
  __local int s[CHARS * CHARS];
  __local int t[(BLOCK + 1) * (BLOCK + 2)];
  int bx = get_group_id(0);
  int tx = get_local_id(0);
  int rr = (br -     bx) * BLOCK + 1;
  int cc = (bc + 2 * bx) * BLOCK + 1;

  int index   = I(rr + tx, cc - tx);
  int index_n = I(rr -  1, cc + tx);
  int index_w = index - 1;
  int ii = 0;

  while (ii + tx < CHARS)
  {
    for (int ty = 0; ty < CHARS; ++ty)
      s[ty * CHARS + ii + tx] = A[ty * CHARS + ii + tx];
    ii += BLOCK;
  }
  barrier(CLK_LOCAL_MEM_FENCE);

  if (bc == 1 && bx == 0)
    for (int m = 0; m < BLOCK; ++m)
    {
      int x = m - tx + 1;
      if (x > 0)
        B[I(rr + tx, x)] = max3(B[I(rr + tx - 1, x - 1)] + s[P[rr + tx] * CHARS + Q[x]],
                                B[I(rr + tx - 1, x    )] - penalty,
                                B[I(rr + tx    , x - 1)] - penalty);
      barrier(CLK_GLOBAL_MEM_FENCE);
    }

  int y0 = (tx + 1) + (BLOCK + 1);
  int y1 = (tx + 1) * (BLOCK + 1);
  t[tx] = B[I(rr + tx - 1, cc - tx - 1)];
  t[y0] = B[index_w];
  t[y1] = B[index_n];
  barrier(CLK_LOCAL_MEM_FENCE);

  int y = P[rr + tx];
  int x = Q[cc - tx];
  for (int k = 0; k < BLOCK; ++k)
  {
    int nextX = Q[cc - tx + k + 1];
    t[(k + 2) * (BLOCK + 1) + tx + 1] = max3(t[k * (BLOCK + 1) + tx] + s[y * CHARS + x],
                                                  t[(k + 1) * (BLOCK + 1) + tx] - penalty,
                                                  t[(k + 1) * (BLOCK + 1) + tx + 1] - penalty);
    x = nextX;
    barrier(CLK_LOCAL_MEM_FENCE);
  }

  for (int k = 0; k < BLOCK; ++k)
    B[I(rr + k, cc - k + tx)] = t[(tx + 2) * (BLOCK + 1) + k + 1];
  barrier(CLK_GLOBAL_MEM_FENCE);

  if (cc + BLOCK == cols)
    for (int m = 0; m < BLOCK; ++m)
    {
      int x = cc + BLOCK + m - tx;
      if (x < cols)
        B[I(rr + tx, x)] = max3(B[I(rr + tx - 1, x - 1)] + s[P[rr + tx] * CHARS + Q[x]],
                                B[I(rr + tx - 1, x    )] - penalty,
                                B[I(rr + tx    , x - 1)] - penalty);
      barrier(CLK_GLOBAL_MEM_FENCE);
    }
}
